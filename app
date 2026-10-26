"""IoT for Psychotherapy: wearable sensor streaming + mood check-ins + therapist dashboard."""
import os, sqlite3, secrets
from datetime import datetime, timedelta
from functools import wraps
from flask import (Flask, g, render_template, request, redirect, url_for,
                   session, flash, abort, jsonify)
from markupsafe import Markup
from werkzeug.security import generate_password_hash, check_password_hash

BASE = os.path.dirname(os.path.abspath(__file__))
DB = os.environ.get("IOT_DB", os.path.join(BASE, "iot_psy.db"))
app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev-change-me")

# Alert thresholds (tune clinically per patient in a real deployment)
HR_HIGH_RESTING = 110     # bpm while steps in the window are low
HRV_LOW = 20              # ms RMSSD
GSR_HIGH = 12.0           # microsiemens
LOW_MOOD = 3
LOW_STEPS = 20


def now():
    return datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(_):
    d = g.pop("db", None)
    if d:
        d.close()


def init_db():
    with sqlite3.connect(DB) as c, open(os.path.join(BASE, "schema.sql")) as f:
        c.executescript(f.read())


def csrf_token():
    if "_csrf" not in session:
        session["_csrf"] = secrets.token_hex(16)
    return session["_csrf"]


app.jinja_env.globals["csrf_token"] = csrf_token


@app.before_request
def guard():
    if request.method == "POST" and not request.path.startswith("/api/"):
        if request.form.get("_csrf") != session.get("_csrf"):
            abort(400, "Invalid form token")
    uid = session.get("uid")
    g.user = get_db().execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone() if uid else None


def login_required(role=None):
    def deco(fn):
        @wraps(fn)
        def wrap(*a, **kw):
            if not g.user:
                return redirect(url_for("login"))
            if role and g.user["role"] != role:
                abort(403)
            return fn(*a, **kw)
        return wrap
    return deco


def own_patient(pid):
    """Therapist may only access their own patients."""
    p = get_db().execute("SELECT * FROM users WHERE id=? AND role='patient' AND therapist_id=?",
                         (pid, g.user["id"])).fetchone()
    if not p:
        abort(404)
    return p


# ---------- charts (server-side SVG, no JS/CDN needed) ----------
def spark(values, w=420, h=90, lo=None, hi=None, color="#3b6ea5", threshold=None):
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return Markup('<div class="muted">Not enough data yet.</div>')
    lo = min(vals) if lo is None else lo
    hi = max(vals) if hi is None else hi
    if hi == lo:
        hi = lo + 1
    n = len(values)
    pts = []
    for i, v in enumerate(values):
        if v is None:
            continue
        x = 4 + i * (w - 8) / (n - 1)
        y = h - 4 - (v - lo) * (h - 8) / (hi - lo)
        pts.append(f"{x:.1f},{y:.1f}")
    line = ""
    if threshold is not None and lo <= threshold <= hi:
        ty = h - 4 - (threshold - lo) * (h - 8) / (hi - lo)
        line = f'<line x1="0" x2="{w}" y1="{ty:.1f}" y2="{ty:.1f}" stroke="#c0392b" stroke-dasharray="4 3"/>'
    return Markup(f'<svg viewBox="0 0 {w} {h}" class="chart">{line}<polyline fill="none" stroke="{color}" '
                  f'stroke-width="2" points="{" ".join(pts)}"/></svg><div class="muted">min {min(vals):.0f} · '
                  f'max {max(vals):.0f} · latest {vals[-1]:.0f}</div>')


app.jinja_env.globals["spark"] = spark


def stress_index(hr, hrv, gsr):
    """Illustrative 0-100 arousal index from the latest reading (NOT a clinical measure)."""
    if hr is None or hrv is None or gsr is None:
        return None
    s = 0.4 * min(max((hr - 60) / 60, 0), 1) + 0.35 * min(max((60 - hrv) / 50, 0), 1) \
        + 0.25 * min(max(gsr / 15, 0), 1)
    return round(100 * s)


app.jinja_env.globals["stress_index"] = stress_index


# ---------- alert engine ----------
def add_alert(db, pid, kind, msg):
    # avoid flooding: one open alert per kind per patient within 30 minutes
    cutoff = (datetime.utcnow() - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S")
    if db.execute("SELECT 1 FROM alerts WHERE patient_id=? AND kind=? AND ts>?", (pid, kind, cutoff)).fetchone():
        return
    db.execute("INSERT INTO alerts(patient_id,ts,kind,message) VALUES(?,?,?,?)", (pid, now(), kind, msg))


def evaluate_reading(db, pid, hr, hrv, gsr, steps):
    if hr is not None and hr > HR_HIGH_RESTING and (steps or 0) < LOW_STEPS:
        add_alert(db, pid, "high_hr", f"Elevated heart rate at rest ({hr:.0f} bpm).")
    if hrv is not None and hrv < HRV_LOW:
        add_alert(db, pid, "low_hrv", f"Low heart-rate variability ({hrv:.0f} ms), possible acute stress.")
    if gsr is not None and gsr > GSR_HIGH:
        add_alert(db, pid, "high_gsr", f"High skin conductance ({gsr:.1f} µS).")


# ---------- device API ----------
@app.route("/api/readings", methods=["POST"])
def api_readings():
    token = request.headers.get("X-Device-Token", "")
    db = get_db()
    p = db.execute("SELECT id FROM users WHERE device_token=? AND role='patient'", (token,)).fetchone() if token else None
    if not p:
        return jsonify(error="invalid device token"), 401
    data = request.get_json(silent=True)
    items = data if isinstance(data, list) else [data]
    saved = 0
    for d in items:
        if not isinstance(d, dict):
            continue
        try:
            hr = float(d["heart_rate"]) if d.get("heart_rate") is not None else None
            hrv = float(d["hrv"]) if d.get("hrv") is not None else None
            gsr = float(d["skin_conductance"]) if d.get("skin_conductance") is not None else None
            steps = int(d.get("steps") or 0)
        except (ValueError, TypeError):
            continue
        if hr is not None and not 20 <= hr <= 250:
            continue
        ts = str(d.get("ts") or now())[:19].replace("T", " ")
        db.execute("INSERT INTO readings(patient_id,ts,heart_rate,hrv,skin_conductance,steps) VALUES(?,?,?,?,?,?)",
                   (p["id"], ts, hr, hrv, gsr, steps))
        evaluate_reading(db, p["id"], hr, hrv, gsr, steps)
        saved += 1
    db.commit()
    return jsonify(saved=saved)


# ---------- auth ----------
@app.route("/")
def index():
    return redirect(url_for("dashboard") if g.user else url_for("login"))


@app.route("/register", methods=["GET", "POST"])
def register():
    """Therapist self-registration. Patients are created by their therapist."""
    if request.method == "POST":
        f = request.form
        if not (f["name"].strip() and f["email"].strip() and len(f["password"]) >= 8):
            flash("All fields required; password min 8 characters.", "error")
        else:
            try:
                db = get_db()
                db.execute("INSERT INTO users(name,email,password_hash,role) VALUES(?,?,?,'therapist')",
                           (f["name"].strip(), f["email"].strip().lower(), generate_password_hash(f["password"])))
                db.commit()
                flash("Account created. Please log in.", "ok")
                return redirect(url_for("login"))
            except sqlite3.IntegrityError:
                flash("Email already registered.", "error")
    return render_template("register.html")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        u = get_db().execute("SELECT * FROM users WHERE email=?", (request.form["email"].strip().lower(),)).fetchone()
        if u and check_password_hash(u["password_hash"], request.form["password"]):
            session.clear()
            session["uid"] = u["id"]
            return redirect(url_for("dashboard"))
        flash("Invalid email or password.", "error")
    return render_template("login.html")


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------- dashboards ----------
@app.route("/dashboard")
@login_required()
def dashboard():
    if g.user["role"] == "patient":
        return redirect(url_for("my_view"))
    db = get_db()
    patients = db.execute("SELECT * FROM users WHERE therapist_id=? ORDER BY name", (g.user["id"],)).fetchall()
    rows = []
    for p in patients:
        r = db.execute("SELECT * FROM readings WHERE patient_id=? ORDER BY ts DESC LIMIT 1", (p["id"],)).fetchone()
        m = db.execute("SELECT * FROM moods WHERE patient_id=? ORDER BY ts DESC LIMIT 1", (p["id"],)).fetchone()
        a = db.execute("SELECT COUNT(*) FROM alerts WHERE patient_id=? AND acknowledged=0", (p["id"],)).fetchone()[0]
        rows.append(dict(p=p, r=r, m=m, alerts=a))
    return render_template("therapist_dashboard.html", rows=rows)


@app.route("/patients/new", methods=["GET", "POST"])
@login_required("therapist")
def patient_new():
    if request.method == "POST":
        f = request.form
        if not (f["name"].strip() and f["email"].strip() and len(f["password"]) >= 8):
            flash("All fields required; password min 8 characters.", "error")
        else:
            token = secrets.token_urlsafe(24)
            try:
                db = get_db()
                db.execute("INSERT INTO users(name,email,password_hash,role,therapist_id,device_token) "
                           "VALUES(?,?,?,'patient',?,?)",
                           (f["name"].strip(), f["email"].strip().lower(),
                            generate_password_hash(f["password"]), g.user["id"], token))
                db.commit()
                flash("Patient added. Their device token is on the patient page.", "ok")
                return redirect(url_for("dashboard"))
            except sqlite3.IntegrityError:
                flash("Email already registered.", "error")
    return render_template("patient_new.html")


def series(db, pid, hours):
    since = (datetime.utcnow() - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
    return db.execute("SELECT * FROM readings WHERE patient_id=? AND ts>=? ORDER BY ts", (pid, since)).fetchall()


def downsample(rows, key, n=120):
    vals = [r[key] for r in rows]
    if len(vals) <= n:
        return vals
    step = len(vals) / n
    return [vals[int(i * step)] for i in range(n)]


@app.route("/patients/<int:pid>")
@login_required("therapist")
def patient_detail(pid):
    p = own_patient(pid)
    hours = request.args.get("hours", 24, type=int)
    hours = hours if hours in (6, 24, 72, 168) else 24
    db = get_db()
    rows = series(db, pid, hours)
    moods = db.execute("SELECT * FROM moods WHERE patient_id=? ORDER BY ts DESC LIMIT 14", (pid,)).fetchall()
    alerts = db.execute("SELECT * FROM alerts WHERE patient_id=? ORDER BY ts DESC LIMIT 30", (pid,)).fetchall()
    notes = db.execute("SELECT * FROM notes WHERE patient_id=? ORDER BY ts DESC", (pid,)).fetchall()
    charts = dict(hr=downsample(rows, "heart_rate"), hrv=downsample(rows, "hrv"),
                  gsr=downsample(rows, "skin_conductance"),
                  mood=[m["score"] for m in reversed(moods)])
    return render_template("patient_detail.html", p=p, hours=hours, charts=charts, moods=moods,
                           alerts=alerts, notes=notes, n=len(rows), HR=HR_HIGH_RESTING, HRV=HRV_LOW, GSR=GSR_HIGH)


@app.route("/patients/<int:pid>/note", methods=["POST"])
@login_required("therapist")
def add_note(pid):
    own_patient(pid)
    body = request.form.get("body", "").strip()
    if body:
        db = get_db()
        db.execute("INSERT INTO notes(patient_id,therapist_id,ts,body) VALUES(?,?,?,?)",
                   (pid, g.user["id"], now(), body))
        db.commit()
    return redirect(url_for("patient_detail", pid=pid))


@app.route("/alerts/<int:aid>/ack", methods=["POST"])
@login_required("therapist")
def ack_alert(aid):
    db = get_db()
    a = db.execute("SELECT a.* FROM alerts a JOIN users u ON u.id=a.patient_id "
                   "WHERE a.id=? AND u.therapist_id=?", (aid, g.user["id"])).fetchone()
    if not a:
        abort(404)
    db.execute("UPDATE alerts SET acknowledged=1 WHERE id=?", (aid,))
    db.commit()
    return redirect(url_for("patient_detail", pid=a["patient_id"]))


# ---------- patient view ----------
@app.route("/me", methods=["GET", "POST"])
@login_required("patient")
def my_view():
    db = get_db()
    if request.method == "POST":
        try:
            score = int(request.form["score"])
            assert 1 <= score <= 10
        except (ValueError, KeyError, AssertionError):
            flash("Pick a mood score from 1 to 10.", "error")
            return redirect(url_for("my_view"))
        note = request.form.get("note", "").strip()[:500]
        db.execute("INSERT INTO moods(patient_id,ts,score,note) VALUES(?,?,?,?)", (g.user["id"], now(), score, note))
        if score <= LOW_MOOD:
            add_alert(db, g.user["id"], "low_mood", f"Low self-reported mood ({score}/10).")
        db.commit()
        flash("Check-in saved. Thank you.", "ok")
        return redirect(url_for("my_view"))
    rows = series(db, g.user["id"], 24)
    moods = db.execute("SELECT * FROM moods WHERE patient_id=? ORDER BY ts DESC LIMIT 14", (g.user["id"],)).fetchall()
    return render_template("patient_home.html", hr=downsample(rows, "heart_rate"),
                           mood=[m["score"] for m in reversed(moods)], moods=moods, n=len(rows))


if __name__ == "__main__":
    init_db()
    app.run(debug=True, port=5000)
