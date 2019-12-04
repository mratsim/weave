# Event notifications and backoff strategies

To save on CPU and power consumption and reduce contention,
threads should limit their synchronization attempts and only
communicate when needed and avoid spurious failures.

For that a backoff strategy needs to be designed.

There are a couple of areas where backoff can be considered:
- Sending a steal request
- Checking incoming steal requests
- Relaying steal requests
- Checking incoming tasks

Challenges:

- In Weave, delay in checking and/or relaying steal requests affect all the
  potential thieves.
  In other runtimes, a thief that backs off will wake up with 0 task,
  in weave it may wake up with 10 steal requests queued.

  As each thread as a parent, a thread that backed off can temporarily give up ownership
  of it's steal request channel to its parent instead

Backoff strategies

There seems to be 2 main strategies worth exploring:
- Consider that each processors work as if in a distributed system
  and reuse research inspired from Wifi/Radio stations, especially
  on wakeup strategies to limit spurious wakeups.
  This is based on a probabistic approach to bound the number of
  attempts and estimate the system throughput.
  Extensive research is done at the end.

- Augment the relevant channels with a companion event signaling system

## Event signaling system

TODO

Windows provides AutoResetEvent and ManualResetEvent that can be directly used for this purpose.

## Distributed backoff and contention resolution strategies

### Overview

The most active domain on backoff is for Wifi and broadband.
Mobile devices need to save power but a router or radio station can only accept
one message at a time so all senders must synchronize and backoff when a conflict is detected.

There are 2 cases: sender backoff and wakeups of radio stations.

Also practical algorithms are kept simple so that they can be implemented efficiently in hardware.
And the major areas of focus are: power consumption, global throughput and latency/fairness (even with adversarial attacks)
which happen to be what we want:
- don't waste CPU cycles when there is nothing to do
- minimize time to send all messages
- ensure that everyone has a fair chance to send his (i.e. a steal request)

Note that a idle worker could use the backoff time to do useful maintenance work
like maintaining its memory pool.
Also this will have interaction with the adaptative thefts

Open question:
Besides exponential backoff, most of the algorithm requires
computing probabilities like 1/2^i (k-selection)
for loglog iterated backoff, increasing contention window size
by W *= 1 + 1/(log log W)

Division is very costly and already a huge penalty
log is awfully expensive and such computation might actually
consume more CPU than a simple truncated exponential backoff

### Research

Note that logstar(65536) == 4 and logstar(2^65536) == 5
For all intents and purposes O(log logstar(N)) is O(1)

#### Presentations

- Michael A. Bender keynote:
  https://www3.cs.stonybrook.edu/~bender/talks/2014-fomc-backoff.pdf
  http://aussois2016.imag.fr/abstracts-slides/Bender.pdf
  https://www.birs.ca/cmo-workshops/2016/16w5152/files/Bender-backoff-oaxaca.pdf

- Amazon AWS, exponential backoff with jitter
  https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/

- Google GCS, truncated exponential backoff
  https://cloud.google.com/storage/docs/exponential-backoff

- Leslie Ann Goldberg's Contention Resolution Notes
  https://www.cs.ox.ac.uk/people/leslieann.goldberg/contention.html

- Simon Lam: Adaptative Backoff algorithms for multiple access: a history
  https://www.cs.utexas.edu/users/lam/NRL/backoff.html

#### Papers

##### Wakeup focused:
- Probabilistic algorithms for the wakeup problem in
  single-hop radio networks
  Jurdzinski et al, 2002
  https://disco.ethz.ch/alumni/pascalv/refs/rn_2002_jurdzinski.ps

- The wakeup problem in synchronous broadcast systems
  Gasieniec et al, 2001
  http://www.csc.liv.ac.uk/~leszek/papers/podc00.ps.gz

##### Backoff and contention resolutions (not wakeup focused)

- Scaling Exponential Backoff:
  Constant Throughput, Polylogarithmic Channel-Access Attempts, and Robustness
  Bender et al, 2019
  https://dl.acm.org/citation.cfm?doid=3299993.3276769
  2016 preprint
  https://www3.cs.stonybrook.edu/~bender/newpub/2016-BenderFiGi-SODA-energy-backoff.pdf

- Contention resolution with constant throughput
  and log-logstar channel accesses
  Bender et al, 2018
  https://web.eecs.umich.edu/~pettie/papers/contention-sicomp.pdf

- Is our model for contention resolution wrong?
  William C Anderton, Maxwell Young, 2017
  https://arxiv.org/abs/1705.09271

  Excellent review of the field:
  - Binary Exponential Backoff
  - LogBackoff and LogLogBackoff
  - Sawtooth backoff

  Note that we don't have the issue of backing off too slowly in work-stealing runtimes
  as we only have collisions if the consumer (victim) accesses the back of the channel at the
  same time as a producer (thief). Thieves don't collide.

- Backoff as Performance improvements Algorithms
  Comprehensive review
  Manaseer Saher, Afnan Alawneh, 2017
  https://pdfs.semanticscholar.org/a7b2/5aaaec662450542d8edffed68ca33f428890.pdf

  Presents:
    - Binary Exponential Backoff (BEB)
    - Multiplicative Increase Multiplicative/Linear Decrease
    - Virtual Backoff
    - Fibonacci Backoff
    - Intelligent Paging Backoff
  with concerns about throughput, auto-adjusting to an unknown number of contending stations (how many thieves do we have)

- Performance Analysis of different backoff algorithms
  for WBAN-based Emerging Sensor Networks
  Khan et al, 2017
  https://www.researchgate.net/publication/314200043_Performance_Analysis_of_Different_Backoff_Algorithms_for_WBAN-Based_Emerging_Sensor_Networks

  Formal modulation as markov Model of Fibonaci and Binary Exponential Backoff

- Unbounded contention reoslution in multiple access channels
  Anta et al, 2013
  http://eprints.networks.imdea.org/559/1/FMRkSel_cameraready.pdf

- Contention Resolution in Multiple-Access Channels:
  k-selection in radio networks
  Anta et al, 2010
  https://www.researchgate.net/publication/227111101_Contention_Resolution_in_Multiple-Access_Channels_k-Selection_in_Radio_Networks

- Contention Resolution with heterogeneous job size
  Bender et al, 2006
  https://groups.csail.mit.edu/tds/papers/Gilbert/ESA06.pdf

- Adversarial contention resolution for simple channels
  Bender et al, 2005
  https://dl.acm.org/citation.cfm?id=1074023
  https://people.csail.mit.edu/bradley/papers/BenderFaHe05.pdf

  Introduces loglog backoff and sawtooth backoff

- Adversarial analysis of window backoff strategies
  Bender et al, 2004
  https://pdfs.semanticscholar.org/f32d/b500eeeedd14154a8523136e970c00910718.pdf
