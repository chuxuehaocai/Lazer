# Lazer product and interface language

Lazer is a calm, intent-driven music space. Any new screen or component must feel like a quiet
sheet of listening notes rather than a technical dashboard.

## Gateway documentation

- The canonical API documentation is <https://music.naominet.dev/docs/>.
- Check this documentation before adding or changing any Gateway route, parameter, login flow,
  response model, cookie behavior, or synchronization logic. Do not infer endpoint behavior from
  UI requirements alone.
- Gateway requests include `randomCNIP=true` by default. Preserve this default unless a deployment
  explicitly provides a stable mainland China `realIP`.

## Design principles

1. **Restraint and calm.** Prefer open space, short copy, soft separation and one clear action.
   Remove decoration that does not explain state or hierarchy. Do not build dense card grids.
2. **Natural language is the primary interface.** Let people describe what they want to hear in
   everyday language. Keep software mechanics secondary. Empty and error states must suggest the
   next useful sentence or action.
3. **Brand inheritance.** Use the semantic tokens and components in `LazerTheme.kt`; never add raw
   feature colors or one-off typography when an existing role fits. Generated or synced content
   must inherit the same type, color, spacing and interaction rules.
4. **Direct manipulation.** When an item can be reordered or moved, prefer drag interaction and
   provide a keyboard-accessible equivalent. Use inline feedback near the changed item.

## Visual tokens

- Light paper `#F7F5EF`, raised paper `#FCFAF5`, mist blue `#A9C8D8`, lake blue `#5F91AC`,
  ink `#26363D`, quiet ink `#627279`, and warm listening accent `#B88769`.
- Dark paper `#1D282D`, raised dark paper `#253238`, dark ink `#E7ECEB`, and action blue
  `#91BED3`. Dark mode must preserve the paper hierarchy; it is not pure black.
- Blue communicates intent, selection and progress. Warm clay is contextual and rare. Red is only
  for destructive actions and errors.
- Use the shared humanist sans-serif scale. Sentence case only. Body copy stays below roughly
  80 characters per line and uses generous line height.
- Default spacing follows a 4 dp rhythm. Main content uses 24–32 dp breathing room. Corner radii
  express hierarchy: 8 dp for small controls, 12–16 dp for fields, and 20–28 dp only for major
  surfaces.

## Interaction rules

- Background motion is discouraged. Motion must answer a user action or communicate a real wait.
- Ripple is a semantic theme token: use pale mist `#EAF4F7` in dark mode and deep lake blue
  `#365F73` in light mode. Do not let transparent surfaces infer a black ripple.
- Loading indicators live in a fixed-size slot and animate internally so surrounding x/y positions
  never move.
- Text inputs must respect font line height and provide at least 48 dp height; never force a Material
  text field below its supported content height.
- Every action has a visible keyboard focus state, an explicit content description, and a stable
  label from action through confirmation.
- QR is the default sign-in route. Password sign-in is the fallback. Gateway credentials are never
  displayed or logged, and sign-out clears the saved session.
- Playlist metadata, complete track lists, and cover images are restored from local cache first,
  then refreshed from Gateway. Prefer one complete request; if the service caps it, append stable
  500-track pages without clearing the already visible cache.
- Light and dark themes must be reviewed together whenever a color, elevation or border changes.

## Voice

Use plain, conversational Chinese. Say what happens: “同步歌单”, “重新生成二维码”, “退出登录”.
Do not expose transport or API terminology unless diagnosing a connection. Errors state what failed
and the next available action; empty screens invite a concrete first step.
