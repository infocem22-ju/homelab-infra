import sys
import subprocess
from pathlib import Path
from PyQt6.QtWidgets import (
    QApplication, QWidget, QPushButton,
    QVBoxLayout, QMessageBox, QTextEdit
)

class ComposeToggle(QWidget):
    def __init__(self):
        super().__init__()

        # dossier où est le script → compose supposé ici
        self.project_dir = Path(__file__).resolve().parent
        self.compose_file = self.project_dir / "docker-compose.yml"

        self.is_on = False

        self.button = QPushButton("START")
        self.button.clicked.connect(self.toggle)

        self.log = QTextEdit()
        self.log.setReadOnly(True)

        layout = QVBoxLayout()
        layout.addWidget(self.button)
        layout.addWidget(self.log)
        self.setLayout(layout)

        self.setWindowTitle("Docker Compose Toggle")
        self.resize(500, 350)

    def run_compose(self, args):
        cmd = ["docker", "compose", "-f", str(self.compose_file)] + args
        result = subprocess.run(
            cmd,
            cwd=self.project_dir,
            capture_output=True,
            text=True
        )
        self.log.append(result.stdout + result.stderr)
        return result.returncode == 0

    def toggle(self):
        if self.is_on:
            reply = QMessageBox.question(
                self,
                "Confirmation",
                "Arrêter les conteneurs ?",
                QMessageBox.StandardButton.Yes |
                QMessageBox.StandardButton.No
            )
            if reply != QMessageBox.StandardButton.Yes:
                return
            success = self.run_compose(["down"])
        else:
            success = self.run_compose(["up", "-d"])

        if success:
            self.is_on = not self.is_on
            self.button.setText("STOP" if self.is_on else "START")
        else:
            self.log.append("⚠️ Problème docker compose")

if __name__ == "__main__":
    app = QApplication(sys.argv)
    w = ComposeToggle()
    w.show()
    sys.exit(app.exec())
