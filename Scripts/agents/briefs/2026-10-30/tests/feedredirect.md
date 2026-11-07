# Task `feedredirect`: HTTP redirects of feeds and episode downloads

Slug `tests-feedredirect`, branch `tests/feedredirect` from `team/tests`. Read `_common.md` beside this file first. Audit item U04 (`build/orchestrator/oct30/tests-audit-untested.md` in the main checkout). Tests only, unless a test shows a bug: then stop and post it to `tests-lead` with the evidence and a proposed fix.

## The code
- `TextMouth/Services/Feeds/FeedNetwork.swift` 337-355: a chain made only of 301 or 308 redirects becomes `permanentURL`; 428-441: the redirect guard in `FeedDataTaskDelegate` (only http and https are followed).
- `TextMouth/Services/Feeds/FeedTransfer.swift` 188-200: the same guard in `FeedDownloadTaskDelegate`, for episode downloads.
- `TextMouth/Services/Feeds/FeedRefresher.swift` 300-310 and 385-389: the subscription's stored address is replaced, and FEED_MOVED is logged.
- A suspected wording bug: when the delegate refuses a redirect, URLSession ends the task with the redirect response itself, so `FeedFetchError.from(status:host:)` (`FeedNetwork.swift` 225-233) may say "... couldn't send the feed (error 301). Try again later." where "That address isn't a web address TextMouth can open." (`.notAWebAddress`) is meant. Your tests show which.
- The stub already redirects: a `StubResponse` whose headers hold `Location` is told to the client as a redirect (`FeedTestSupport.swift`, `steps(of:for:)`, the `Location` branch). Serve `StubResponse(status: 301, headers: ["Location": "https://<host>/new.xml"])` then the feed at the new path. A redirect to `ftp://` or `file://` cannot be served by the stub, but the guard sees only the request: give `Location` such an address.

## Tests (new class `FeedRedirectTests`, new file, `xcodegen generate`; build worlds as `FeedRefresherTests` does)
1. 301 then 200: the stored address is updated, one FEED_MOVED line is logged (read how feed tests capture diagnostic lines), and the record is saved with it.
2. 308: the same.
3. 302, and 307: the address is unchanged.
4. 301 then 302: unchanged, since the chain must be all permanent.
5. 301 then 304 with an ETag: `.notModified(permanentURL:)` still updates the address.
6. A redirect to `ftp://...` and to `file:///etc/hosts`: not followed, the address unchanged, and the listener's sentence pinned exactly. If it is the "error 301" sentence, stop and post it to `tests-lead` as a likely wording bug with your proposed fix (in `FeedNetwork.swift`, a refused redirect reported as `.notAWebAddress`); do not change production code before the answer.
7. An episode enclosure redirected to `file://`: nothing is downloaded or written into the feed's folder, and the item's failure sentence is pinned.
8. A redirect loop (A to B to A) stops with a sentence: pin it.

## Proof
Make the guard allow any scheme, and make the permanent-chain check accept a 302: the matching tests fail; restore.

## Classes to run
`FeedRedirectTests FeedRefresherTests FeedDownloadTests`. Files: the new test file and `project.pbxproj`; `FeedTestSupport.swift` only if the stub truly needs a change (say why). Never reach the network: every host is a stub's.
