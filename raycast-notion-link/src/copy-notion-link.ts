import { perform } from "./command";

export default async function Command(): Promise<void> {
  await perform("copy");
}
