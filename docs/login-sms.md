# SMS code sign-in

Phone + SMS-code sign-in, checked against
`neteaseCloudMusicApiEnhanced/api-enhanced`
(`module/captcha_sent_v1.js`, `module/login_cellphone.js`).

## The two calls

| Step | Alias | Upstream | Encoding |
| --- | --- | --- | --- |
| Send the code | `/captcha/sent/v1` | `/api/middle/captcha/sent/v1` | eapi |
| Sign in | `/login/cellphone` | `/api/w/login/cellphone` | weapi |

The send body is `ctcode`, `secrete: music_middleuser_pclogin`,
`cellphone`, `scene: '0'`. The login body is `type: '1'`, `https: 'true'`,
`phone`, `countrycode`, `remember: 'true'`, `secureCaptcha`, plus **either**
`captcha` (this flow) **or** the MD5 password — never both.

A successful login answers `code: 200` with `account`, `profile` and the
rotated session cookies. The transport attaches the merged cookie set to the
reply; the gateway installs it before the account lookup, exactly like the QR
flow.

## Why the send call matters for the session

`/api/middle/captcha/sent/v1` is an anonymous eapi call, and the server answers
it with device cookies (`NMTID`, `_ntes_nuid`, …). api-enhanced keeps the whole
response jar, so the login that follows presents the same visitor. This client
does the same: the transport forwards the `/captcha/sent/v1` cookie set and
`NeteaseGateway.sendCaptcha` stores it in the session before returning.

## What the card does

- The sign-in card switches between 扫码 / 短信验证码 / 密码 / Cookie; switching
  away from the QR tab cancels its poll timer.
- The phone field is `+86` and accepts an 11-digit mainland number; the code
  field accepts 4–6 digits.
- `获取验证码` calls `AppState.sendSmsCode` and starts a 60-second resend
  cooldown; the success line and errors render inside the card.
- `登录` calls `AppState.signInWithPhoneCaptcha`, and a confirmed session is
  persisted under `lazer_gateway_cookie` with `AuthMethod.sms`.
- Risk control (`secureCaptcha` / Yidun `sca`) is passed through by
  `NeteaseGateway.loginWithPhoneCaptcha`, but the card has no Yidun solver — a
  rejected attempt simply reports the service message.
