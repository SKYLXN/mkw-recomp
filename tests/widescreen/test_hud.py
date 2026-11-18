"""The race HUD at the screen edges (MKW_HUD_POSITION=edges): the real host_pane_matrix of patches.c over authored
pane fixtures (1.8.0's RaceInfo_1 and MiniMap_01 names, parents and depths only); no game required."""

import os
import subprocess

import pytest

from test_list_masks import masks  # noqa: F401  (the compiled pane-matrix fixture)

WIDE = 2560 / 1080 / (16 / 9)
TALL = 2448 / 1848 / (16 / 9)


def dock(exe, scale, name, parent, above, x, y, position="edges", split=0, icon=None, race=True):
    env = {**os.environ, "HUD": position}
    env.pop("RACE", None)
    if race:
        env["RACE"] = "1"
    if icon:
        env["ICON"] = f"{icon[0]},{icon[1]}"
    args = [str(exe), str(scale), name, parent, str(above), str(x), "100", str(split), str(y)]
    out = list(map(float, subprocess.check_output(args, env=env).split()))
    return out[4], out[6], out[7:]


@pytest.mark.parametrize(
    "name,parent,above,x,y,ax,ay",
    [
        ("L_ItemSlot_00", "N_Root", 1, -780, 420, -1, 1),
        ("N_Pers_00", "N_Root", 1, -800, -430, -1, -1),
        ("L_Rank_00", "N_Root", 1, 780, -400, 1, -1),
        ("L_Timer_00", "N_TimeAttack_00", 2, 700, 440, 1, 1),
        ("L_ItemWarning_00", "N_Root", 1, 0, -380, 0, -1),
    ],
)
def test_race_hud_goes_to_its_edges_on_wider_and_taller_outputs(masks, name, parent, above, x, y, ax, ay):  # noqa: F811
    tx, ty, _ = dock(masks, WIDE, name, parent, above, x, y)
    assert (tx, ty) == (pytest.approx(x + ax * 960 * (WIDE - 1)), y)
    tx, ty, _ = dock(masks, TALL, name, parent, above, x, y)
    assert (tx, ty) == (x, pytest.approx(y + ay * 540 * (1 / TALL - 1)))


@pytest.mark.parametrize(
    "scale,name,parent,above,x,y,position,split",
    [
        (WIDE, "L_ItemSlot_00", "N_Root", 1, -780, 420, "16:9", 0),  # the default: the console's place
        (1, "L_ItemSlot_00", "N_Root", 1, -780, 420, "edges", 0),  # 16:9
        (WIDE, "L_ItemSlot_00", "N_Root", 1, -100, 100, "edges", 0),  # carried to the middle by an animation
        (WIDE, "L_ItemSlot_00", "N_ChangeLayout_00", 1, -780, 420, "edges", 0),  # split screen's RaceInfo_2/4
        (WIDE, "L_ItemSlot_00", "N_Root", 2, -780, 420, "edges", 0),  # another depth
        (WIDE, "L_ItemSlot_00", "N_Root", 1, -780, 420, "edges", 1),  # a split camera view in the last frames
        (WIDE, "L_Timer_00", "N_All_00", 1, 700, 440, "edges", 0),  # Mission_00's timer
    ],
)
def test_other_panes_positions_and_outputs_keep_their_place(masks, scale, name, parent, above, x, y, position, split):  # noqa: F811
    assert dock(masks, scale, name, parent, above, x, y, position, split)[:2] == (x, y)


@pytest.mark.parametrize("scale", [WIDE, TALL])
def test_minimap_docks_right_and_its_icons_follow_it_in_a_race(masks, scale):  # noqa: F811
    x, y = 760, -150
    tx, ty, icon = dock(masks, scale, "P_Map_00", "N_SunLight_00", 3, x, y, icon=(770, -140))
    dx = 960 * (scale - 1) if scale > 1 else 0
    dy = y * (1 / scale - 1) if scale < 1 else 0
    assert (tx, ty) == (pytest.approx(x + dx), pytest.approx(y + dy))
    assert icon == pytest.approx([770 + dx, -140 + dy])
    # out of a race (the title's demo map), or outside the map's rect, an N_All_00 root pane stays
    assert dock(masks, scale, "P_Map_00", "N_SunLight_00", 3, x, y, icon=(770, -140), race=False)[2] == [770, -140]
    assert dock(masks, scale, "P_Map_00", "N_SunLight_00", 3, x, y, icon=(-500, 300))[2] == [-500, 300]
