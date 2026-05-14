// Shared scene-transition discriminants. The top-level scene loop in
// `index.ts` cycles between lobby and game; each scene resolves with a
// `SceneResult` telling the loop where to go next.

export type SceneResult =
  | { kind: "lobby" }
  | { kind: "game"; code: string };
