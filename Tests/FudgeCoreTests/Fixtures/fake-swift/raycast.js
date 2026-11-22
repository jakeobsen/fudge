export async function greet(name) {
  return await runSwiftFunction("greet", name)
}

export async function fail() {
  return await runSwiftFunction("fail")
}
