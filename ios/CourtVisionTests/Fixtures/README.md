# Test fixtures

Clips replayed through the engine by `EngineReplayTests` (off-device
regression) and scored by `tools/eval_events.py` against the `.gt.csv` next
to them.

## freethrow.mp4

- Source: Wikimedia Commons, *"Marianna Tolo — lancer franc — Open LFB 2014"*
  by Chris93, CC BY-SA 4.0 —
  https://commons.wikimedia.org/wiki/File:Marianna_Tolo-lancer_franc-Open_LFB_2014.ogv
- One free throw filmed courtside from near the baseline (rim at frame left,
  shooter at the line, jersey numbers visible). 1080p, 4.47 s.
- Transcoded Theora → H.264 (libx264, crf 23, 30 fps) and the last frame is
  held for 3 s (total 7.47 s) so the shot-event window can expire inside the
  clip. Nothing else was altered.
- `freethrow.gt.csv`: release at ~1.7 s, ball through the net at ~2.9 s →
  made; shot from the free-throw line (25, 19) on the standard half court.
- Known limit: the unified model labels this set shot `player-in-possession`
  then `player-shot-block`, never `player-jump-shot`, and never emits
  `ball-in-basket` for the frame-edge rim — so the shot pipeline cannot open
  an attempt here. `EngineReplayTests` therefore asserts rim/ball/player
  tracking on this clip; a courtside **jump-shot** clip is wanted for the
  attempt/make assertion.

## Ground-truth CSV schema

```
attempt_s,made,x_ft,y_ft
```

`attempt_s` = seconds from clip start (the release); `made` 1/0; `x_ft,y_ft`
in feet on the standard half court, origin at the left end of the baseline,
rim center at (25, 5.25), free-throw line at y = 19.

Field clips for the P1 baseline live outside git (`~/courtvision-clips/`);
list them here by name, source and date when their `.gt.csv` is added.
