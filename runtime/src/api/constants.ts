// @raycast/api's enums that are exports of their own. Their values come from
// Raycast's type definitions (see scripts/raycast-types.ts), so extensions
// that compare or store them see exactly what they would in Raycast.

import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";

export const Icon = Object.freeze({ ...RAYCAST_ENUMS.Icon });
export const Color = Object.freeze({
    ...RAYCAST_ENUMS.Color,
    // Deprecated in Raycast, and a dynamic color rather than an enum member, so its value isn't in the types.
    Brown: Object.freeze({ light: "#9A6324", dark: "#C08A4E" }),
});
export const ImageMask = Object.freeze({ ...RAYCAST_ENUMS.ImageMask });
/** `Image` is mostly types; its one value is `Image.Mask`. */
export const Image = Object.freeze({ Mask: ImageMask });
export const LaunchType = Object.freeze({ ...RAYCAST_ENUMS.LaunchType });
export const PopToRootType = Object.freeze({ ...RAYCAST_ENUMS.PopToRootType });
