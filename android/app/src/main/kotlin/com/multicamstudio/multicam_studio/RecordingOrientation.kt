package com.multicamstudio.multicam_studio

/**
 * VideoRenderService joins camera files by copying samples, so the merged
 * video carries a single orientation hint (the first file's) for every
 * camera. Front cameras report 270° and back cameras 90°, which turned the
 * front camera's shots upside down in the final video.
 *
 * A file's hint is therefore always 0° or 90° (a back camera's): frames at
 * 180° or 270° are encoded turned by 180°. The check runs on every frame,
 * because the camera operator (or the admin) can switch lenses mid-take and
 * the frames' rotation changes with it. Each file still plays upright on
 * its own.
 */
internal fun uprightHint(rotation: Int): Int = if (rotation >= 180) rotation - 180 else rotation

/** Whether a frame at [rotation] must be turned by 180° to match [fileHint]. */
internal fun needsHalfTurn(rotation: Int, fileHint: Int): Boolean =
    ((rotation - fileHint) % 360 + 360) % 360 == 180
