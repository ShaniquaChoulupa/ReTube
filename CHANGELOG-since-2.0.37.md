# TubeReplacer changelog since 2.0.37 (2.0.38 → 2.0.73)

## YouTube 12.x
- 2.0.38–2.0.39  First InnerTube bridge for 12.x (YTBaseInnerTubeService transport); fixed launch crash (missing NSURLConnection requestWithRequest:).
- 2.0.40–2.0.47  12.x /next response class; web-cookie sign-in (SSOLoginScopedAuthorization / SSOOAuth2SignIn pointed at the web login); identity-based auth in the bridge; sign-in callback ordering fix; sign-in tracing.
- 2.0.48–2.0.52  accounts_list answered locally from the signed-in account (no more empty-list crash), correct item-section level, self-check of the generated response.
- 2.0.53 + follow-ups  Channel tab crash fixed, Channels tab, community posts as text, mix playlists via /next, inline channel tab contents (tabs no longer spin), channel header/subscribe buttons/grid flattening/timestamps.

## YouTube 11.x
- 2.0.56  Real subscribe/like forwarding to YouTube, like button in /next, drop empty channel tabs.
- 2.0.62  11.10.9 launch crash fixed (+[NSURLConnection userAgent] missing).
- Sign-in on 11.10.9 / 11.19.7 fixed: setParameters/completionHandler crashes, user profile supplied to the sign-in handler, sign-in callback looked up late (it was nil), identity saved (2.0.67).
- 2.0.68–2.0.69  accounts_list answered locally / returns an error instead of an empty list (crash after sign-in and on the Accounts tab).
- Playlist thumbnails (thumbnailRenderer) on compact playlists (2.0.63).
- 2.0.70–2.0.72  Signed-in auth captured through SSOIdentityPrivate (fixes "error fetching channel list" and anonymous requests); account name/photo loaded from the web account menu.

## YouTube 13.x
- 2.0.57  First-pass 13.x support: channel header layout, banners, button width.
- 2.0.58  Header avatar below banner, theme-coloured subscribe button, title fix, duration overlay.
- 2.0.59  Schema reflection for Google's GPB runtime (dataType/fieldType/enum names).
- 2.0.60–2.0.61  /next uses slimVideoMetadataRenderer (title, subtitle, owner, like/dislike); correct like/dislike icon types.

## Home feed
- Signed-out home feed now shows the curated trending playlist (VLPLbgMm37FwiYk, honours the TrendingBrowseId preference) instead of searching "trending"; search kept as last resort (2.0.70–2.0.71).

## Comments (11.x / 13.x apps that have the comment cells)
- Comments loaded in /next from the web's comment threads (first page + continuation).
- Comments header with count and "Add a public comment…" box; posting works and the new comment appears (uses the real comment returned by YouTube).
- Replies: first replies of the first threads shown inline.
- Like/dislike buttons no longer drawn as liked (vote status sent as INDIFFERENT).
- Fixed a memory blow-up (jetsam) caused by scanning the whole response per comment.
- Skipped on 2.9.3 / 10.x (older comment system) and 2.3.1 (no InnerTube comments).

## Classic / old apps
- Classic YouTube on iOS 5.1.1: object-subscripting polyfill (fixes crash).
- 2.0.37 and earlier work (≤2.2.0 /next, NSURL refs) unchanged.

## Channels / UI
- Classic (non-"newer") subscribe button style on v11+.

## Known gaps
- "View all replies" tap, comment liking/disliking, reply styling.
- Captions/HD on 2.1.0+, upload on 12.x, validation of v10/v13 channel behaviour.
