import { List } from "@raycast/api";
import { useState } from "react";
import { greeting } from "./lib/greeting";

export default function Command() {
    const [name] = useState("fudge");
    return (
        <List>
            <List.Item title={greeting(name)} />
        </List>
    );
}
