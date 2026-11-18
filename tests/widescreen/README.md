# tests/widescreen

Window aspect, FOV and the UI fitting of ultrawide and tall windows.

| File | What it checks |
|---|---|
| `test_aspect.py` | Window aspect, horizontal FOV, UI fitting and unchanged 16:9/wide/version defaults |
| `test_vertplus.py` | The actual late race-FOV hook over repeated requests and tall render-target dimensions |
| `test_vertplus_gate.py` | Old game tables without the separate FOV set fail closed to 16:9 |
| `test_list_masks.py` | The pane-matrix hook (1.8.0): its sites; on a wider output the character and kart lists' capture masks (the outer one to the screen edge, every one drawn wide where it was); the race and pause prompts' corner and 16:9 shape on wider and taller outputs; other panes and split screens left alone |
| `test_hud.py` | The race HUD at the screen edges (`MKW_HUD_POSITION=edges`): each piece to its edge on wider and taller outputs, the minimap and its icons, and the default, 16:9, split screens, animations and other layouts left alone |
| `test_ui_capture.py` | Actual draw hook, full-canvas backdrops, character/kart masks, cup backdrop, ordinary controls and movies |
