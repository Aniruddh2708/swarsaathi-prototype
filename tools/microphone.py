"""Run: python -m tools.microphone devices | record --seconds 4 --output recordings/voice.wav"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import threading
import time
import wave

import numpy as np

from audio.capture import AudioCapture, AudioError, list_input_devices


def record_wav(path, seconds=4.0, device=None, sample_rate=44100):
    if not np.isfinite(seconds) or not 0.1 <= seconds <= 300:
        raise ValueError("Recording duration must be between 0.1 and 300 seconds")
    path = Path(path)
    if path.exists():
        raise ValueError(f"Refusing to overwrite existing recording: {path}")
    frames = []
    finished = threading.Event()
    captured = 0
    capture = None

    def accept(frame):
        nonlocal captured
        frames.append(frame.samples.copy())
        captured += len(frame.samples)
        if captured >= round(seconds * frame.sample_rate):
            finished.set()

    capture = AudioCapture(device=device, sample_rate=sample_rate, window_size=512,
                           block_size=512, on_frame=accept)
    capture.start()
    try:
        deadline = time.monotonic() + seconds + 5
        while not finished.wait(0.05):
            if capture.error or not capture.running:
                raise AudioError(capture.error or "Microphone stopped unexpectedly")
            if time.monotonic() >= deadline:
                raise AudioError("Microphone delivered insufficient samples before timeout")
    finally:
        capture.stop()
    if capture.metrics['dropped_samples'] or capture.metrics['overruns']:
        raise AudioError(f"Recording interrupted by lost audio: {capture.metrics}. Retry without heavy CPU load.")
    signal = np.concatenate(frames)[:round(seconds * capture.sample_rate)]
    pcm = (np.clip(signal, -1, 1) * 32767).astype('<i2')
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation protects existing vocal recordings even in a race.
    with path.open('xb') as output:
        with wave.open(output, 'wb') as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(capture.sample_rate)
            writer.writeframes(pcm.tobytes())
    return dict(path=str(path), seconds=len(signal) / capture.sample_rate,
                sample_rate=capture.sample_rate, rms=float(np.sqrt(np.mean(signal.astype(float) ** 2))),
                peak=float(np.max(np.abs(signal))), metrics=capture.metrics)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('devices', help='List genuine microphone devices')
    recording = commands.add_parser('record', help='Record an actual microphone to mono PCM16 WAV')
    recording.add_argument('--seconds', type=float, default=4)
    recording.add_argument('--output', required=True)
    recording.add_argument('--device', type=int)
    recording.add_argument('--sample-rate', type=int, default=44100)
    args = parser.parse_args(argv)
    try:
        if args.command == 'devices':
            devices = list_input_devices()
            print(json.dumps(devices, indent=2))
            if not devices:
                print('No input devices. Run this command on the evaluation laptop with a microphone.')
                return 2
        else:
            print(json.dumps(record_wav(args.output, args.seconds, args.device, args.sample_rate), indent=2))
    except (AudioError, ValueError, OSError) as exc:
        print(f'Audio diagnostic failed: {exc}')
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
