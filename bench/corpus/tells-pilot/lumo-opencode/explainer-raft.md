# How leader election works in Raft

Raft is a consensus algorithm designed to be understood. Its central idea is that a cluster of servers elects a single leader, and that leader manages all decisions until it fails or loses contact. Everything else in Raft, log replication and safety, builds on that one mechanism. This explainer covers how an election starts, how it finishes, and how Raft avoids the failure modes that make naive designs break down.

## The cast of characters

A Raft cluster typically has an odd number of servers: three, five, or seven. Each server is in exactly one of three states at any time:

- **Follower**: the default state. Followers respond to requests from a leader and cast votes when asked. Followers initiate nothing.
- **Candidate**: a transitional state used during elections. A candidate campaigns to become leader.
- **Leader**: at most one per term. The leader handles all client writes and sends replication traffic to followers.

Raft divides time into **terms**, which are logical clock intervals numbered with increasing integers. Terms are central to Raft's mental model. Every term has at most one leader, and terms never go backwards: each server stores its current term number and rejects any message carrying an older term. If a server receives a message with a newer term than its own, it immediately adopts that term and, if it was a candidate or leader, demotes itself to follower. Think of terms as an sequence of historical epochs. A term with a successful election has a leader; a term with a failed election has none, and the next term starts fresh.

Each server also persists a small piece of state before voting: its current term and the candidate it voted for in that term. This durability is what prevents a server from voting twice in the same term after a crash and reboot.

## Heartbeats

Under normal operation, the leader stays leader without holding a formal election again. It does this with **heartbeats**: empty `AppendEntries` RPCs sent to every follower at regular intervals, say every 50 milliseconds. A heartbeat carries the leader's term and serves two purposes. First, it tells followers "a valid leader exists, stay a follower." Second, it advances the follower's knowledge of the term.

Followers reset an internal countdown timer each time they receive a valid heartbeat. As long as heartbeats arrive, followers never campaign. When heartbeats flow, the system is quiet and cheap: no elections, no campaigning, just steady replication traffic.

Note that heartbeats and log replication share the same RPC. An `AppendEntries` request with log entries is also a heartbeat. There is no separate mechanism to keep alive.

## Election timeouts

What happens when the leader dies or becomes unreachable? No one sends heartbeats, so no follower resets its timer. Eventually a follower's **election timeout** fires, typically a randomized value between 150 and 300 milliseconds, and that follower takes action:

1. It increments its current term, transitions to candidate state, and votes for itself.
2. It sends `RequestVote` RPCs to every other server in the cluster.
3. It waits for one of three outcomes.

The three possible outcomes are:

- **It wins the election.** A candidate needs votes from a majority of the cluster (a quorum: 2 of 3, 3 of 5). Reaching that count includes its own self-vote. Upon winning, it becomes leader, immediately sends heartbeats to all peers to establish authority and suppress any other pending candidacies, and begins serving clients.
- **It receives a valid `AppendEntries` from a new leader.** If the message carries a term at least as high as the candidate's current term, the candidate accepts reality, returns to follower state, and resumes normal operation.
- **It learns of a higher term.** If any RPC reply arrives with a term greater than its own, the candidate immediately converts to follower and updates its term.

The election timeout is deliberately much longer than the heartbeat interval, so a healthy leader can always preempt a timeout before it fires.

## Why the timeout is randomized

Suppose all followers fire their timeouts simultaneously. Every server becomes a candidate in the same instant, every server votes for itself, and nobody can reach a majority. Raft handles this with randomization: each server draws its election timeout independently from a range, so one follower usually times out first, campaigns, and wins before the others wake up. Randomization converts a coordination problem into a race with a strong favorite. In practice this resolves most elections on the first attempt.

## Split votes

Sometimes the race still ties. Two followers can time out close enough together that each gathers some votes but neither reaches a majority. This is a **split vote**. For example, in a five-server cluster, two candidates each get two votes, leaving neither with the required three.

A split vote means the term ends with no leader. Candidates detect this by timing out again while still in the candidate state. Each then starts a *new* election: increment the term, vote for self, solicit votes. Because each candidate draws a fresh random timeout, one will almost certainly start before the others and win the new term outright.

This is why split votes in Raft are a delay, not a corruption. Progress stalls for one extra election period, then the cluster converges. The worst case, everyone timing out in lockstep forever, has vanishing probability because the random draws are independent each round.

## Rules that keep elections safe

Two voting rules make elections trustworthy:

- **One vote per term, persistently recorded.** A server votes at most once per term, granting its vote on a first-come, first-served basis among valid candidates. Because the vote is persisted, a crashed-and-recovered server cannot double vote.
- **Log completeness check.** A voter only grants its vote to a candidate whose log is at least as up-to-date as its own, comparing the length of each log and the term of the last entry. This guarantees that any elected leader already holds all committed entries, so it never needs to fetch missing data from anyone else.

Combined with majority quorums, these rules give Raft its core safety property called the **Election Safety** guarantee: at most one candidate can win any given term. Any two majorities overlap in at least one server, and that server cannot have voted for two candidates in the same term.

## Putting it together

The lifecycle is simple to trace. A leader heartbeats; followers reset timers. The leader dies; a follower's random timeout fires; that follower campaigns on a new term. It either collects a majority and starts heartbeating, learns a newer leader exists, or hits a split vote and retries in the next term with fresh randomness. Terms monotonically increase throughout, giving the cluster a shared sense of which elections supersede which.

For junior engineers, the key insight is this: Raft replaces complicated distributed coordination with a timeout race guarded by persistent, once-per-term votes and monotonic term numbers. When debugging a Raft system, check timers first. A misconfigured election timeout too close to the heartbeat interval is the classic cause of a cluster that elects leaders endlessly.
