# ReTube 1.3

**New in 1.3**
- **720p playback.** Videos start on the iPhone app's HLS stream list (H.264 + AAC, 240p up to 720p, best first) instead of the single 360p file. YouTube is asked in the background while the normal 360p request runs; the stream is checked before it is used, and if YouTube refuses it (or anything goes wrong) the video plays at 360p like before. (If a video will not play at all after this update, switch "720p HD playback" off.) Three failures in a row pause HD for 5 minutes. Switch: Settings > ReTube > "720p HD playback" (also needs "Enable HLS" on). The quality picker still applies: with 720p off in it, the cap drops to 480p, then 360p. 1080p is left out on purpose.
- **More suggested videos.** The watch page now follows the suggestions list for two extra pages (about three times as many videos, duplicates removed) instead of stopping at the first ~20.
- **Bigger video tiles (best effort).** The picture in the suggested-video rows is made about 25% larger when the row can hold it. If the app lays rows out in a way this cannot reach, nothing changes. The first three rows are described in TubeReplacer.log ("tile #1 ...") so it can be done exactly next time. Switch: "Bigger video tiles".

Log lines to look for: `hd:` (720p), `related:` (extra suggestions), `tile #` (row layout).

---

ReTube is a rebranded build of **TubeReplacer** by Preloading (https://github.com/Preloading/TubeReplacer), licensed GPLv3. Original copyright and license are kept (see LICENSE). Package maintained by Jeremy.

---

<div align="center">
<img src="https://github.com/Preloading/TubeReplacer/blob/main/preferences/Resources/icon@full.png" width=20% height=20%>
<h1>TubeReplacer</h1>
  
![Hackatime Badge](https://hackatime-badge.hackclub.com/U091X12CFFG/TubeReplacer)

</div>

###### it's like tuberepair but i replaced the whole backend of the app, instead of the server

## What is this?
This is a cydia tweak that fixes the google youtube app, versions 1.0.0-2.0.0, in a form where it does not rely on a backend server. This allows for such luxuries as signin.

## Versions
Should work on iOS 5-iOS 10. Built originally with youtube versions 1.0.1, with that version being fully featured with minor execptions, however, it should work on 1.0.0-2.0.0, though some new features added in those versions may not work. If anything in this category is wrong, leave a github issue or contact me.

## What doesn't work
- Purchases (bruh)
- Age Restricted Content*
- Add Channel button. This is a list of channels, and I have no idea what to put there.
- Viewing whether or not you actually liked a video. I don't know if this was in this version or not.

## Contact/Support
There are a few ways you can contact me
- Email, you can just straight up email me. My email is `me@preloading.dev`. The fun part about this method is it still works on iOS 6! And 5. And 4. And 3. And 2. And 1 (probably). I promise I don't bite :)
- Send in a github issue.
- I guess on the bag.xml discord server somewhere.
- Make a post on reddit or smth. I read it sometimes.
- If you issue with the app or tweak, the crash reporter & the send feedback button redirects to me, so you can send stuff there.
