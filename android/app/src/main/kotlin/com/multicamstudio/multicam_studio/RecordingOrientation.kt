package com.multicamstudio.multicam_studio

/**
 * VideoRenderService joins camera files by copying samples, so the merged
 * video carries a single orientation hint (the first file's) for every
 * camera. Front cameras report 270° and back cameras 90°, which turned the
 * front camera's shots upside down in the final video.
 *
 * Frames at 180° or 270° are therefore encoded turned by 180°, bringing their
 * hint to 0° or 90° like a back camera's. Each file still plays upright on
 * its own.
 */
internal fun needsUprightTurn(rotation: Int): Boolean = rotation >= 180

internal fun uprightHint(rotation: Int): Int =
    if (needsUprightTurn(rotation)) rotation - 180 else rotation
