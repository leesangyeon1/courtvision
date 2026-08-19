"""Draw engine Moments onto the source clip — the "what did the engine see" video.

    TEST_RUNNER_COURTVISION_REPLAY_CLIP=/abs/clip.mov xcodebuild … test \
        -only-testing:CourtVisionTests/EngineReplayTests/testReplayClipFromEnvironment
    .venv/bin/python tools/render_moments.py clip.mov clip.moments.json out.mp4

Team A blue, team B red, unassigned cyan, referees black, rims orange with
the end letter, ball yellow circle; label = #number or track id + action.
Needs the repo .venv (opencv)."""
import cv2, json, sys, bisect
src, moments, out = sys.argv[1], sys.argv[2], sys.argv[3]
M = json.load(open(moments)); times = [m['pts'] for m in M]
cap = cv2.VideoCapture(src); fps = cap.get(cv2.CAP_PROP_FPS); W = int(cap.get(3)); H = int(cap.get(4))
wr = cv2.VideoWriter(out, cv2.VideoWriter_fourcc(*'mp4v'), fps, (W, H))
COL = {'A': (255, 120, 0), 'B': (0, 0, 255), None: (255, 255, 0)}   # BGR: A blue, B red, none cyan
def R(b): x, y, w, h = b[0][0], b[0][1], b[1][0], b[1][1]; return int(x*W), int(y*H), int((x+w)*W), int((y+h)*H)
i = 0
while True:
    ok, fr = cap.read()
    if not ok: break
    t = i / fps; i += 1
    k = bisect.bisect_right(times, t) - 1
    if k >= 0 and t - times[k] < 0.4:
        m = M[k]
        for end, rim in m['rims'].items():
            x0, y0, x1, y1 = R(rim); cv2.rectangle(fr, (x0, y0), (x1, y1), (0, 140, 255), 2); cv2.putText(fr, end, (x0, max(12, y0-4)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 140, 255), 2)
        for ref in m['referees']:
            x0, y0, x1, y1 = R(ref); cv2.rectangle(fr, (x0, y0), (x1, y1), (0, 0, 0), 2)
        for p in m['players']:
            x0, y0, x1, y1 = R(p['box']); c = COL.get(p.get('team'))
            cv2.rectangle(fr, (x0, y0), (x1, y1), c, 2)
            lab = f"#{p['number']}" if p.get('number') else f"t{p['trackId']}"
            if p['action'] != 'none': lab += " " + p['action'][:4].upper()
            cv2.putText(fr, lab, (x0, max(12, y0-4)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, c, 2)
        if m.get('ball'):
            x0, y0, x1, y1 = R(m['ball']['box']); cv2.circle(fr, ((x0+x1)//2, (y0+y1)//2), max(6, (x1-x0)//2), (0, 255, 255), 2)
        cv2.putText(fr, f"t={t:4.1f}s players={len(m['players'])}", (10, H-12), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
    wr.write(fr)
wr.release(); print("wrote", out, i, "frames")
