// Form.DatePicker.isFullDay and Action.PickDate.isFullDay: whether a date is
// a whole day, as a DatePicker of type Date gives (local midnight exactly).

export function isFullDay(date: Date | null | undefined): boolean {
    if (!(date instanceof Date) || Number.isNaN(date.getTime())) return false;
    return date.getHours() === 0 && date.getMinutes() === 0 && date.getSeconds() === 0 && date.getMilliseconds() === 0;
}
