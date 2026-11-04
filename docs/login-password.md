# Email / phone password sign-in

Email-or-phone + password sign-in, checked against the official Android client
`NeteaseCloudMusic_Music_official_9.6.08.261015102648_3264.apk`
(`PassLoginFragmentV2`, `CellphoneLoginFragmentV3`, `tf0/i`, `NeteaseMusicUtils`).

## Official client behaviour

- The phone sign-in card carries a `密码登录` pill; the mail icon opens the
  `登录邮箱` page. Both pages use a password field plus a `登录` button.
- `PassLoginFragmentV2` trims the email, keeps the password verbatim, and calls
  `tf0/i.z(email, password, checkToken, captchaToken)`.
- `CellphoneLoginFragmentV3` calls
  `tf0/i.h(phone, password, checkToken, captchaToken)`.
- Both paths hash the password with `NeteaseMusicUtils.a`: plain **MD5**, then
  `b(byte[])` formats it as **lowercase hex**. The email path first truncates
  the password to 16 characters (`tf0/i.z`); the phone path hashes the full
  password (`tf0/i.h`).
- Neither page sends the password in clear text. `checkToken` and
  `secureCaptcha` are the client's risk-control slots; this client leaves them
  empty and reports the service message when risk control rejects a login.

## Client mapping

| Step | Alias | Upstream | Encoding | Body |
| --- | --- | --- | --- | --- |
| Email + password | `/login` | `/api/w/login` | weapi | `type: '0'`, `https: 'true'`, `username`, `password` (MD5 of first 16 chars), `rememberLogin: 'true'` |
| Phone + password | `/login/cellphone` | `/api/w/login/cellphone` | weapi | `type: '1'`, `https: 'true'`, `phone`, `countrycode`, `remember: 'true'`, `password` (MD5 of full password), `secureCaptcha` |

`NeteaseGateway.loginWithEmail` computes the 16-character MD5 and passes it as
the route's `md5_password` override, matching the official client. The phone
route hashes the full password in `lib/gateway/routes.dart`.

## What the card does

- The sign-in card adds `密码登录` alongside 扫码 / 短信验证码 / Cookie.
- One `手机号或邮箱` field: an address containing `@` takes the email path,
  an 11-digit mainland number takes the phone path. `+86` is the country code.
- The password field is obscured, with 显示密码 / 隐藏密码 in the suffix.
- `登录` calls `AppState.signInWithPassword`, which dispatches to
  `signInWithEmail` or `signInWithPhonePassword`; a confirmed session is
  persisted under `lazer_gateway_cookie` with `AuthMethod.password`.
- The account detail shown on the account card is masked (`li***@example.com`,
  `138****0000`).
- `忘记密码？` opens `https://music.163.com/#/forgetpassword` in the system
  browser; if no browser is available the card shows the URL instead.
- Risk control (`secureCaptcha` / Yidun `sca`) is passed through by the
  gateway but the card has no Yidun solver — a rejected attempt reports the
  service message.

## Exporting the session cookie

Settings → 账户 → `导出 Cookie` copies the active `gateway.sessionCookie` to
the system clipboard. The row is disabled while signed out and hidden for
Navidrome, which does not use a NetEase cookie.
