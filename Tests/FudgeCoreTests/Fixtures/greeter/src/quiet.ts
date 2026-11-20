import { greeting } from "./lib/greeting";

export default async function Command(props: { arguments: { who?: string } }) {
    console.log(greeting(props.arguments.who ?? "nobody"));
}
