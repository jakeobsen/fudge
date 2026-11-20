// @raycast/api's enums that are exports of their own. Their values come from
// Raycast's type definitions (see scripts/raycast-types.ts), so extensions
// that compare or store them see exactly what they would in Raycast.

import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";

export const Icon = Object.freeze({ ...RAYCAST_ENUMS.Icon });
export const Color = Object.freeze({ ...RAYCAST_ENUMS.Color });
export const LaunchType = Object.freeze({ ...RAYCAST_ENUMS.LaunchType });
export const PopToRootType = Object.freeze({ ...RAYCAST_ENUMS.PopToRootType });
