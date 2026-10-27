"""Launch the local desktop app: python main.py."""
import argparse
import logging
from pathlib import Path
import sys

from PyQt6.QtWidgets import QApplication
from PyQt6.QtCore import QTimer

from ui.main_window import MainWindow


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke-test', action='store_true',
                        help='Construct all three views, briefly run Qt, then exit. Does not validate audio hardware.')
    args = parser.parse_args()
    log_dir = Path(__file__).resolve().parent / 'logs'
    log_dir.mkdir(exist_ok=True)
    logging.basicConfig(level=logging.INFO,
                        format='%(asctime)s %(levelname)s %(name)s %(message)s',
                        handlers=[logging.FileHandler(log_dir / 'swarsaathi.log', encoding='utf-8'),
                                  logging.StreamHandler()])
    app = QApplication(sys.argv)
    app.setApplicationName('SwarSaathi')
    window = MainWindow()
    window.show()
    if args.smoke_test:
        if window.views.count() != 3:
            raise RuntimeError('Expected three desktop workflow views')
        QTimer.singleShot(350, window.close)
        QTimer.singleShot(500, app.quit)
        logging.info('Desktop startup smoke test; microphone hardware is not validated by this check.')
    return app.exec()


if __name__ == '__main__':
    raise SystemExit(main())
