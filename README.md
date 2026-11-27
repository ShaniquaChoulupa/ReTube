# ReTube 1.4

**New in 1.4 (fixes for 1.3)**
- **720p playback, new method.** 1.3 asked YouTube for the iPhone app's HLS list; YouTube no longer gives that list out for normal videos, so 720p could never start. Now ReTube takes YouTube's separate 720p video (H.264) and audio (AAC) streams and joins them into one ordinary MP4 on the iPad itself (no re-encoding, served from 127.0.0.1), then offers it next to the 360p stream. The links are tested first; if YouTube refuses them, or the merge fails, the video plays at 360p like before. YouTube cuts these links off after about a minute, so the merge asks for new links by itself while you watch. Videos longer than 25 minutes are not merged (they play at 360p). Switch: Settings > ReTube > "720p HD playback"; the quality picker's 720p switch still applies. 1080p is left out on purpose. Starting a video can take a few seconds longer while the merge is prepared.
- **Suggested videos, signed in.** The extra suggestions from 1.3 only appeared when signed out; the list is now found in signed-in answers too.
- **Bigger video tiles.** 1.3 hooked a row class this YouTube version does not use. 1.4 also hooks the cell classes of the suggested rows and writes what they look like to the log, so it can be done exactly if the guess does nothing.

**From 1.3**
- More suggested videos (two extra pages, duplicates removed, up to 90).
- "Bigger video tiles" switch.

Log lines to look for in /var/mobile/Documents/TubeReplacer.log: `hd:` (720p: which client, link tests, merge result), `mux:` (stream links refreshed or refused while playing), `related:` (extra suggestions), `tile #` (row layout).

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
