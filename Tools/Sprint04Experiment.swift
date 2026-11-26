import Foundation
import Dispatch

@main
struct Sprint04Experiment {
    struct InputError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Audio {
        let rate: Double
        let samples: [Float]

        init(url: URL) throws {
            let data = try Data(contentsOf: url)
            func tag(_ i: Int) -> String { String(decoding: data[i..<i + 4], as: UTF8.self) }
            func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
            func u32(_ i: Int) -> Int { Int(u16(i)) | Int(u16(i + 2)) << 16 }
            let invalid = InputError(message: "Expected a mono 16-bit PCM WAV file with a valid sample rate.")
            guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw invalid }
            var offset = 12, pcm: Range<Int>?, sampleRate: Double?
            while offset + 8 <= data.count {
                let size = u32(offset + 4), start = offset + 8, end = start + size
                guard end <= data.count else { throw invalid }
                switch tag(offset) {
                case "fmt ":
                    guard size >= 16, u16(start) == 1, u16(start + 2) == 1,
                          u16(start + 12) == 2, u16(start + 14) == 16 else { throw invalid }
                    sampleRate = Double(u32(start + 4))
                case "data": pcm = start..<end
                default: break
                }
                offset = end + size % 2
            }
            guard let pcm, !pcm.isEmpty, pcm.count.isMultiple(of: 2),
                  let sampleRate, (8000...192000).contains(sampleRate) else { throw invalid }
            rate = sampleRate
            samples = stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map {
                Float(Int16(bitPattern: u16($0))) / 32768
            }
        }
    }


    struct Label { let time: Double; let hz: Double }
    struct Inference {
        let frames: [PitchFrame]
        let config: PitchConfig
        let medianMs: Double?
    }
    static func labels(_ path: String, audio: Audio) throws -> [Label] {
        var rows: [Label] = []
        for line in try String(contentsOfFile:path,encoding:.utf8).split(whereSeparator:\.isNewline) {
            let c=line.split(separator:",")
            guard c.count==2, let t=Double(c[0]), let hz=Double(c[1]), t.isFinite, hz.isFinite, t>=0, hz>=0,
                  t <= Double(audio.samples.count)/audio.rate, t > (rows.last?.time ?? -.infinity) else {
                throw InputError(message:"Invalid label")
            }
            rows.append(Label(time:t,hz:hz))
        }
        guard rows.count>1 else { throw InputError(message:"Empty labels") }
        return rows
    }
    static func infer(_ samples: [Float], rate: Double) -> Inference {
        let c=PitchConfig.forCapture(sampleRate:rate), d=YINPitchDetector(sampleRate:rate,config:c)
        var frames:[PitchFrame]=[], times:[Double]=[]
        samples.withUnsafeBufferPointer { p in
            var i=0
            while i+c.frameSize<=p.count {
                let start=DispatchTime.now().uptimeNanoseconds
                frames.append(d.analyze(p.baseAddress!+i,count:c.frameSize,time:Double(i+c.frameSize/2)/rate))
                times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
                i += c.hopSize
            }
        }
        return Inference(frames:frames,config:c,medianMs:PitchMath.median(times))
    }
    static func frameIndex(_ t:Double,_ a:Inference,_ rate:Double) -> Int {
        AttributionResearch.nearestWindow(time:t,rate:rate,frame:a.config.frameSize,hop:a.config.hopSize)
    }
    static func frame(_ t:Double,_ a:Inference,_ rate:Double) -> PitchFrame? {
        let i=frameIndex(t,a,rate)
        return a.frames.indices.contains(i) ? a.frames[i] : nil
    }
    struct Counts: Codable {
        var voiced=0, unvoiced=0, within=0, missed=0, falseVoiced=0, octaves=0
        var medianCents:Double?, p95Cents:Double?
    }
    static func measure(_ rows:[Label],_ a:Inference,_ rate:Double, shift:Double=0) -> Counts {
        var m=Counts(), errors:[Double]=[]
        for l in rows {
            let f=frame(l.time+shift,a,rate)?.rawFrequency
            if l.hz==0 { m.unvoiced += 1; if f != nil { m.falseVoiced += 1 }; continue }
            m.voiced += 1
            guard let f else { m.missed += 1; continue }
            let e=abs(PitchMath.cents(detected:f,expected:l.hz))
            errors.append(e)
            if e<=50 { m.within += 1 }
            if DevelopmentOctaveError.offset(detected:f,reference:l.hz) != nil { m.octaves += 1 }
        }
        m.medianCents=PitchMath.median(errors)
        if !errors.isEmpty { m.p95Cents=errors.sorted()[Int(ceil(0.95*Double(errors.count)))-1] }
        return m
    }
    struct Event: Codable {
        let kind:String, time:Double, window:Int, detectedHz:Double, referenceHz:Double
        let confidence:Double, rms:Double, boundaryMs:Double?, nearbyMatch:Bool
        let windowVoicedFraction:Double?, correlationDetected:Double?, correlationReference:Double?
        let octaveOffset:Int?
    }
    struct Attribution: Codable {
        let counts:Counts, falseBins:[String:Int], octaveBins:[String:Int]
        let falseUniqueWindows:Int, octaveUniqueWindows:Int
        let falseRuns:Int, octaveRuns:Int, longestFalseRunMs:Double, longestOctaveRunMs:Double
        let falseNearbyMatch:Int, octaveNearbyMatch:Int
        let octaveStableReference:Int, octaveReferenceCorrHigher:Int
        let shifts:[String:Counts], events:[Event]
    }
    static func attribution(_ audio:Audio,_ rows:[Label]) -> Attribution {
        let a=infer(audio.samples,rate:audio.rate)
        var boundaries:[Double]=[]
        for i in 1..<rows.count where (rows[i].hz>0) != (rows[i-1].hz>0) {
            boundaries.append((rows[i].time+rows[i-1].time)/2)
        }
        let extent=(Double(a.config.frameSize)+Double(a.config.hopSize))/2/audio.rate
        var events:[Event]=[], fb:[String:Int]=[:], ob:[String:Int]=[:]
        var stable=0, corrHigher=0
        for l in rows {
            guard let p=frame(l.time,a,audio.rate), let f=p.rawFrequency else { continue }
            let octave=DevelopmentOctaveError.offset(detected:f,reference:l.hz)
            guard l.hz==0 || octave != nil else { continue }
            let i=frameIndex(l.time,a,audio.rate)
            let d=AttributionResearch.boundaryDistance(time:l.time,boundaries:boundaries)
            let bin:String
            if let d, d<=extent { bin="windowPlusHalfHop" }
            else if let d, d<=0.100 { bin="within100ms" }
            else { bin="interiorOver100ms" }
            if l.hz==0 { fb[bin,default:0] += 1 } else { ob[bin,default:0] += 1 }
            let nearby=rows.filter { abs($0.time-l.time)<=0.100 && $0.hz>0 }
            let matches=nearby.contains { abs(PitchMath.cents(detected:f,expected:$0.hz))<=50 }
            let inside=rows.filter { abs($0.time-p.time)<=Double(a.config.frameSize)/2/audio.rate }
            let fraction: Double? = inside.isEmpty ? nil : Double(inside.filter{$0.hz>0}.count)/Double(inside.count)
            let c1=AttributionResearch.correlation(samples:audio.samples,start:i*a.config.hopSize,count:a.config.frameSize,lag:Int((audio.rate/f).rounded()))
            let c2=l.hz>0 ? AttributionResearch.correlation(samples:audio.samples,start:i*a.config.hopSize,count:a.config.frameSize,lag:Int((audio.rate/l.hz).rounded())) : nil
            if octave != nil {
                if !inside.isEmpty && inside.allSatisfy({$0.hz>0 && abs(PitchMath.cents(detected:$0.hz,expected:l.hz))<=50}) { stable += 1 }
                if let c1,let c2,c2>c1+0.05 { corrHigher += 1 }
            }
            events.append(Event(kind:l.hz==0 ? "falseVoiced":"octave",time:l.time,window:i,detectedHz:f,referenceHz:l.hz,
                confidence:p.confidence,rms:p.level,boundaryMs:d.map{$0*1000},nearbyMatch:matches,windowVoicedFraction:fraction,
                correlationDetected:c1,correlationReference:c2,octaveOffset:octave))
        }
        let falseEvents=events.filter{$0.kind=="falseVoiced"}, octaveEvents=events.filter{$0.kind=="octave"}
        let intervals=(1..<rows.count).map { rows[$0].time-rows[$0-1].time }
        let step=PitchMath.median(intervals) ?? 0.01
        func runs(_ e:[Event]) -> (Int,Double) {
            var count=0, longest=0.0, first=0.0, last = -Double.infinity
            for x in e {
                if x.time-last>1.5*step { count += 1; first=x.time }
                last=x.time; longest=max(longest,last-first+step)
            }
            return (count,longest*1000)
        }
        let fr=runs(falseEvents), or=runs(octaveEvents)
        var shifts:[String:Counts]=[:]
        for ms in [-40,-20,-10,0,10,20,40] { shifts[String(ms)]=measure(rows,a,audio.rate,shift:Double(ms)/1000) }
        return Attribution(counts:measure(rows,a,audio.rate),falseBins:fb,octaveBins:ob,
            falseUniqueWindows:Set(falseEvents.map{$0.window}).count,octaveUniqueWindows:Set(octaveEvents.map{$0.window}).count,
            falseRuns:fr.0,octaveRuns:or.0,longestFalseRunMs:fr.1,longestOctaveRunMs:or.1,
            falseNearbyMatch:falseEvents.filter{$0.nearbyMatch}.count,octaveNearbyMatch:octaveEvents.filter{$0.nearbyMatch}.count,
            octaveStableReference:stable,octaveReferenceCorrHigher:corrHigher,shifts:shifts,events:events)
    }
    struct MixtureResult: Codable {
        let scenario:String, source:String, delay:Int, gain:Double, fitCorrelation:Double
        let attenuationDb:Double, residualRMS:Double, voiceRMS:Double
        let clean:Counts, mixed:Counts, cancelled:Counts
        let cleanAcceptedPreserved:Int, cleanAccepted:Int, cancellationMs:Double
    }
    static func rms(_ a:[Float]) -> Double { sqrt(a.reduce(0.0){$0+Double($1)*Double($1)}/Double(max(1,a.count))) }
    static func mixture(_ voice:[Float],_ rows:[Label],rate:Double,source:String) throws -> [MixtureResult] {
        let delay: Int = Int(rate * 0.004)
        let maxDelay: Int = delay + 32
        var state:UInt64=2601
        let probe=(0..<4096).map { _ -> Float in
            state=state &* 6364136223846793005 &+ 1
            return Float(Double(state>>32)/Double(UInt32.max)*2-1)*0.1
        }
        func echo(_ r:[Float],_ delay:Int,_ gain:Double,_ second:Bool=false) -> [Float] {
            var out=[Float](repeating:0,count:r.count)
            for i in delay..<r.count {
                out[i]=Float(gain)*r[i-delay]
                if second && i>=delay+31 { out[i] += 0.12*r[i-delay-31] }
            }
            return out
        }
        let calibration=echo(probe,delay,0.5)
        guard let model=ReferenceEchoModel.fit(reference:probe,microphone:calibration,maxDelay:maxDelay) else {
            throw InputError(message:"Calibration failed")
        }
        // Playback-like continuous harmonic signal. Matching-note stress case uses
        // a singer waveform at the same fundamental; no adaptation during singing.
        var reference: [Float] = []
        reference.reserveCapacity(voice.count)
        for i in 0..<voice.count {
            let t: Double = Double(i)/rate
            let phase: Double = 2 * Double.pi * 275 * t
            let primary: Double = 0.12 * sin(phase)
            let harmonic: Double = 0.035 * sin(2 * phase)
            reference.append(Float(primary + harmonic))
        }
        let clean=infer(voice,rate:rate)
        let specs:[(String,Int,Double,Bool)]=[("matched",delay,0.5,false),("gainChanged",delay,0.65,false),
            ("delayChanged",delay+8,0.5,false),("extraReflection",delay,0.5,true)]
        var result:[MixtureResult]=[]
        for spec in specs {
            let leak=echo(reference,spec.1,spec.2,spec.3)
            let mixed=zip(voice,leak).map { $0.0+$0.1 }
            guard mixed.allSatisfy({abs($0)<1}) else { throw InputError(message:"Mixture clipping") }
            let t=DispatchTime.now().uptimeNanoseconds
            guard let cancelled=model.subtract(reference:reference,microphone:mixed) else { throw InputError(message:"Subtraction failed") }
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-t)/1e6
            let residual=zip(cancelled,voice).map{$0.0-$0.1}
            let remaining=rms(residual), attenuation=20*log10(max(rms(leak),1e-12)/max(remaining,1e-12))
            let m=infer(mixed,rate:rate), c=infer(cancelled,rate:rate)
            var preserved=0, accepted=0
            for l in rows where l.hz>0 {
                guard let f=frame(l.time,clean,rate)?.rawFrequency else { continue }
                accepted += 1
                if let g=frame(l.time,c,rate)?.rawFrequency, abs(PitchMath.cents(detected:g,expected:f))<=10 { preserved += 1 }
            }
            result.append(MixtureResult(scenario:spec.0,source:source,delay:model.delay,gain:model.gain,fitCorrelation:model.calibrationCorrelation,
                attenuationDb:attenuation,residualRMS:remaining,voiceRMS:rms(voice),clean:measure(rows,clean,rate),
                mixed:measure(rows,m,rate),cancelled:measure(rows,c,rate),cleanAcceptedPreserved:preserved,cleanAccepted:accepted,cancellationMs:elapsed))
        }
        return result
    }
    static func main() throws {
        let args=CommandLine.arguments
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        if args.count==4 && args[1]=="attribution" {
            let audio=try Audio(url:URL(fileURLWithPath:args[2]))
            let r=try labels(args[3],audio:audio)
            print(String(decoding:try encoder.encode(attribution(audio,r)),as:UTF8.self))
        } else if args.count==4 && args[1]=="mixture" {
            let audio=try Audio(url:URL(fileURLWithPath:args[2]))
            let r=try labels(args[3],audio:audio)
            // Reduce voice amplitude deterministically for controlled double-talk.
            let v=audio.samples.map{$0*0.25}
            print(String(decoding:try encoder.encode(mixture(v,r,rate:audio.rate,source:"humanQuarterAmplitude")),as:UTF8.self))
        } else if args.count==2 && args[1]=="synthetic" {
            let rate=44100.0, n=Int(rate*3)
            var all:[MixtureResult]=[]
            for f in [0.0,220,275] {
                var voice = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let t: Double = Double(i)/rate
                    if t < 0.75 || t >= 2.25 || f <= 0 { continue }
                    let phase: Double = 2 * Double.pi * f * t
                    let primary: Double = 0.035 * sin(phase + 0.7)
                    let harmonic: Double = 0.01 * sin(2 * phase + 0.2)
                    voice[i] = Float(primary + harmonic)
                }
                let r=(0..<300).map { i -> Label in
                    let t=Double(i)/100
                    return Label(time:t,hz:t>=0.75 && t<2.25 ? f:0)
                }
                all += try mixture(voice,r,rate:rate,source:"synthetic-\(Int(f))Hz")
            }
            print(String(decoding:try encoder.encode(all),as:UTF8.self))
        } else { throw InputError(message:"Usage: attribution|mixture WAV CSV, or synthetic") }
    }
}
