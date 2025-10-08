[ ] Rewrite fieldOffset() interfaces to be individual inlined methods for performance
    [X] RingBuffer
    [ ] CoreHeap (pending refactor)
[X] Refactor RingBuffer to use raw memory unbounded array
[ ] Complete ThreadPool implementation
    [X] Memory structure
    [X] Init
    [ ] Work
[ ] Refactor CoreHeap:
    [ ] Integrate RingBuffer for freelist
    [ ] Integrate ThreadPool for background grows and deferred allocation