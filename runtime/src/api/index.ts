// fudge's implementation of @raycast/api. Extensions get this module when
// they import "@raycast/api"; its exports follow vendor/raycast-api/index.d.ts.

export { Action, ActionPanel, Detail, Form, Grid, List, MenuBarExtra } from "./components.ts";
export { Color, Icon, Image, ImageMask, LaunchType, PopToRootType } from "./constants.ts";
export { useNavigation } from "./navigation.ts";
export { getPreferenceValues, openCommandPreferences, openExtensionPreferences } from "./preferences.ts";
export { OAuth } from "./oauth.ts";
export { environment } from "./environment.ts";
export { launchCommand } from "./launch-command.ts";
export { updateCommandMetadata } from "./command-metadata.ts";
export {
    Cache,
    LocalStorage,
    allLocalStorageItems,
    clearLocalStorage,
    getLocalStorageItem,
    removeLocalStorageItem,
    setLocalStorageItem,
} from "./storage.ts";
export {
    Clipboard,
    clearClipboard,
    copyTextToClipboard,
    getApplications,
    getDefaultApplication,
    getFrontmostApplication,
    getSelectedFinderItems,
    getSelectedText,
    open,
    pasteText,
    showInFinder,
    trash,
} from "./system.ts";
export {
    Alert,
    AlertActionStyle,
    Toast,
    ToastStyle,
    captureException,
    clearSearchBar,
    closeMainWindow,
    confirmAlert,
    popToRoot,
    showHUD,
    showToast,
} from "./feedback.ts";
export { Keyboard } from "./keyboard.ts";
export { WindowManagement } from "./window-management.ts";

// Raycast's old names, still exported by @raycast/api.
import { Action, ActionPanel, Form, List } from "./components.ts";
export const ActionPanelItem = Action;
export const ActionPanelSection = ActionPanel.Section;
export const ActionPanelSubmenu = ActionPanel.Submenu;
export const CopyToClipboardAction = Action.CopyToClipboard;
export const OpenAction = Action.Open;
export const OpenInBrowserAction = Action.OpenInBrowser;
export const OpenWithAction = Action.OpenWith;
export const PasteAction = Action.Paste;
export const PushAction = Action.Push;
export const ShowInFinderAction = Action.ShowInFinder;
export const SubmitFormAction = Action.SubmitForm;
export const TrashAction = Action.Trash;
export const ListItem = List.Item;
export const ListSection = List.Section;
export const FormCheckbox = Form.Checkbox;
export const FormDatePicker = Form.DatePicker;
export const FormDropdown = Form.Dropdown;
export const FormDropdownItem = Form.Dropdown.Item;
export const FormDropdownSection = Form.Dropdown.Section;
export const FormSeparator = Form.Separator;
export const FormTagPicker = Form.TagPicker;
export const FormTagPickerItem = Form.TagPicker.Item;
export const FormTextArea = Form.TextArea;
export const FormTextField = Form.TextField;
