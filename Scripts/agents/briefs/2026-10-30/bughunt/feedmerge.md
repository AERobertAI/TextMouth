# bughunt-feedmerge: a deleted episode stays deleted, and a merge that never reached disk is made again

Worker slug `bughunt-feedmerge`, branch `bughunt/feedmerge` (from `team/bughunt`). Read `README.md` beside this file first. Two fixes, one commit each, each with its tests. Both were verified by the lead by reading. No test touches the network: grep `FeedRefresherTests` for its stand-in network.

## 1. One read of a feed that does not list a deleted episode forgets the deletion; the episode then comes back as new and downloads again
`FeedReconciler.merge` (`TextMouth/Services/Feeds/FeedReconciler.swift:79-189`) keeps a deleted item's record only while the feed lists it: `candidates += matcher.unclaimed.filter { $0.deletedDate == nil }` (`:137`). `kept(...)` (`:201-224`) keeps every deleted item it is given, outside the kept-entries count. So when a publisher's server serves, once, an empty or cut-short but valid channel, every deletion it does not list is dropped, and at the next full read the deleted episode is added anew: unplayed, marked new, counted in Unopened, and downloaded again by the newest-N rule (`FeedNewestRule.swift:113-121`, `:188-190`).

Fix: an unlisted deleted item stays in the record for 90 days after its deletion (`deletedDate`), then goes, as today's rule says it goes "once nothing can bring it back". One named constant with a doc comment (why 90 days: long enough to outlast a publisher's bad reads and a feed's window moving back, short enough that a record does not grow without end), and one small function deciding whether an unclaimed item is kept, used at `:137`. A deleted item the feed lists is handled as today. Update the comment at `:135-136` and the type's doc comment if it states the old rule.

Tests, in `FeedRefresherTests`, beside `testADeletedItemNeverComesBack` (`:235`; copy its setup): delete an item, refresh with a valid channel holding no items, then with the full feed again: the item is still deleted, not new, and not asked for by the newest-N rule. And an item deleted more than 90 days before a refresh that does not list it is dropped (pass the refresh's `now`, as the class does).

## 2. A merge whose record write was deferred or failed is never made again
In `FeedRefresher` (`TextMouth/Services/Feeds/FeedRefresher.swift`), the `.read` branch (`:321-351`) merges into the store's record (`store.update`, which writes it on the write queue, `FeedStore.swift:345-391`) and then saves the fetch state's validators and the body's digest unconditionally (`:345-351`). The record write can be deferred (the data directory unavailable: `FeedStore.swift:380-383`, kept in `unsavedFeedIDs` only in memory) or fail (`:403-418`), while the fetch state, in this Mac's caches, is written. If TextMouth then quits (nothing asks when the volume is away) or crashes, the next launch loads the old record, sends the saved ETag (a 304) or gets the same bytes, whose digest equals the saved one (`:433-434`, `:453-455`), and reports "unchanged" at every check: the new episodes stay hidden until the feed changes, which a finished show never does.

Fix:
1. `FeedFetchState` (`TextMouth/Services/Feeds/FeedFetchState.swift:14-40`) gains the record's `feed.updatedDate` as it stood after the merge of the last body read (optional, decoded leniently as its other optional fields are, so an older fetch state still decodes), saved beside `bodyDigest` in the `.read` branch from the record as the store holds it after `store.update`.
2. `fetchAndRead` (`:420-470`) counts the last body (`lastBodyCounts`, `:431`) only when that saved date equals the loaded record's `feed.updatedDate`, compared to the whole second (both rounded down), as the files store dates: a record that never took the merge has an older date, so the feed is read whole and merged again. `updatedDate` changes only when the kept items change (`FeedReconciler.swift:184-187`), so a merge that changed nothing keeps the digest trusted.
3. Comment both, with why. A fetch state from before this change, which has no date, counts as not merged: one full read per feed, once.

Tests, in `FeedRefresherTests` (grep how it makes a store and a second engine on the same folders, and how a store's location is made unavailable; ask the lead if neither exists): a refresh that adds a third item while the store cannot write; a second engine, on the same folders, as after a relaunch, refreshing with the same body (or a 304), ends with the third item in its record and reports the feed updated. And a refresh after a merge that was written still reports unchanged for the same body, as today (an existing test may pin it already: run it).

## Run
`FeedRefresherTests FeedReconcilerTests FeedNewestRuleTests FeedFetchStateTests FeedItemRecordTests FeedStoreTests` (grep each; drop any that does not exist and say so).

## Do not touch
The download manager, `FeedLibraryPresentation.swift` (team `views`), and the matching of items (a feed that changes both guid and enclosure is a follow-up, not this task).
