// HeadsUpCore: the stores, the action registry, the LLM layer, the tool gate,
// storage and every UI string (ADR-001 §1). It imports only Foundation,
// Observation, CSQLite and Markdown, so it builds and is tested on Linux.
// `just lint` fails if an Apple-only framework is imported here.
//
// The UI reads the stores' state and changes it only through their methods.
// `AppModel` owns the stores and the ports, the protocols the macOS shell implements.
