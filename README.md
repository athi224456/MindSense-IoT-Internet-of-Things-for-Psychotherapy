MindSense IoT — Internet of Things for Psychotherapy
Wearable sensor data (heart rate, HRV, skin conductance, steps) streams to a Flask server
over a token-authenticated REST API. Patients log mood check-ins; therapists monitor
trends, receive threshold alerts, and keep session notes.
Architecture
    Wearable / simulator --HTTP POST /api/readings (X-Device-Token)--> Flask + SQLite
                                                                    |-- alert engine (HR, HRV, GSR, mood)
                                                                    |-- therapist dashboard (SVG trend charts)
                                                                    '-- patient portal (mood check-in)

Run
    pip install -r requirements.txt
    python seed.py                                  # demo data
    python app.py                                   # http://127.0.0.1:5000
    python simulator.py --token demo-device-token   # live fake wearable (add --stress for an episode)

Demo logins (password demo12345): therapist@demo.com, patient@demo.com
API
    POST /api/readings   header: X-Device-Token
    body: {"ts":"2026-01-01 10:00:00","heart_rate":72,"hrv":50,"skin_conductance":4.1,"steps":3}
          (or a JSON list of such objects)

Files
    app.py  schema.sql  seed.py  simulator.py  templates/  static/

Important notes
The arousal index and alert thresholds are illustrative, not clinically validated.
Health data is sensitive: obtain informed consent, use HTTPS, set SECRET_KEY, run with debug off,
and follow HIPAA/GDPR/local rules before any real use.
Real hardware: replace generate() in simulator.py with sensor reads (e.g. MAX30102 + GSR on ESP32/Raspberry Pi).
