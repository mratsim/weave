// Weave
// Copyright (c) 2019 Mamy André-Ratsimbazafy
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

#include <stdlib.h>
#include <stdio.h>
#include <threads.h>
#include <atomic>

#if 0
// Normal C++
#include <assert.h>
#define MODEL_ASSERT(...) assert(__VA_ARGS__)
#define thrd_join(thr) thrd_join(thr, nullptr)
#define user_main(...) main(__VA_ARGS__)
#else
// CDSChecker
#include <model-assert.h>
#endif

static const int Padding = 64;

#define LOG(...) {printf(__VA_ARGS__); fflush(stdout);}

template <typename T>
struct Enqueueable {
  std::atomic<Enqueueable*> next;
  T payload;
};

template <typename T>
class ChannelMpscUnboundedBatch
{
  private:
    alignas(Padding) std::atomic<Enqueueable<T>*> m_back;
    std::atomic<int> m_count;
    alignas(Padding) Enqueueable<T> m_front;

  public:
    void initialize(){
      // Ensure no false positive
      m_front.next.store(nullptr, std::memory_order_relaxed);
      m_back.store(&m_front, std::memory_order_relaxed);
      m_count.store(0, std::memory_order_relaxed);
    }

    bool trySend(Enqueueable<T>* src){
      // Send an item to the back of the channel
      // As the channel has unbounded capacity, this should never fail

      m_count.fetch_add(1, std::memory_order_relaxed);
      src->next.store(nullptr, std::memory_order_release);
      auto oldBack = m_back.exchange(src, std::memory_order_acq_rel);
      // Consumer can be blocked here, it doesn't see the (potentially growing)
      //  end of the queue until the next instruction.
      oldBack->next.store(src, std::memory_order_release);

      return true;
    }

    bool tryRecv(Enqueueable<T>** dst){
      // Try receiving the next item buffered in the channel
      // Returns true if successful (channel was not empty)
      // This can fail spuriously on the last element if producer
      // enqueues a new element while the consumer was dequeueing it

      auto first = m_front.next.load(std::memory_order_acquire);
      if (first == nullptr) {
        // Apparently may read from uninitialized load here
        // std::atomic_thread_fence(std::memory_order_acquire); // sync first.next.load(moRelaxed)
        return false;
      }

      // Fast path
      {
        auto next = first->next.load(std::memory_order_acquire);
        if (next != nullptr) {
          // not competing with producers
          __builtin_prefetch(first);
          m_count.fetch_sub(1, std::memory_order_relaxed);
          m_front.next.store(next, std::memory_order_relaxed);
          *dst = first;
          // std::atomic_thread_fence(std::memory_order_acquire); // sync first.next.load(moRelaxed)

          MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
          return true;
        }
      }
      // end fast-path

      // Competing with producers at the back
      auto last = m_back.load(std::memory_order_acquire);
      if (first != last) {
        // We lose the competition before even trying
        // std::atomic_thread_fence(std::memory_order_acquire); // sync first.next.load(moRelaxed)
        return false;
      }

      m_front.next.store(nullptr, std::memory_order_acquire);
      if (m_back.compare_exchange_strong(last, &m_front, std::memory_order_acq_rel)) {
        // We won and replaced the last node with the channel front
        __builtin_prefetch(first);
        m_count.fetch_sub(1, std::memory_order_relaxed);
        *dst = first;

        MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
        return true;
      }

      // We lost but now we know that there is an extra node coming very soon
      auto next = first->next.load(std::memory_order_acquire);
      while (next == nullptr) {
        // spinlock
        thrd_yield();
        next = first->next.load(std::memory_order_acquire);
      }

      __builtin_prefetch(first);
      m_count.fetch_sub(1, std::memory_order_relaxed);
      m_front.next.store(next, std::memory_order_relaxed);     // We are the only reader of next, no sync needed
      // std::atomic_thread_fence(std::memory_order_acquire); // sync first.next.load(moRelaxed)
      *dst = first;

      MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
      return true;
    }

    //   Alternative impl - seems to lead to livelock in the runtime
    //
    //   // We lost but now we know that there is an extra node coming very soon
    //   auto next = first->next.load(std::memory_order_relaxed);
    //   if (next != nullptr) {
    //     // Extra node after this one, no competition with producers
    //     __builtin_prefetch(first);
    //     m_count.fetch_sub(1, std::memory_order_relaxed);
    //     m_front.next.store(next, std::memory_order_relaxed);
    //     atomic_thread_fence(std::memory_order_acquire);
    //     *dst = first;
    //     return true;
    //   }

    //   // The last item wasn't linked to the list yet, bail out
    //   return false;
    // }

  bool trySendBatch(Enqueueable<T>* first, Enqueueable<T>* last, int count){
    // Send a list of items to the back of the channel
    // They should be linked together by their next field
    // As the channel has unbounded capacity this should never fail
    m_count.fetch_add(count, std::memory_order_relaxed);
    last->next.store(nullptr, std::memory_order_release);

    auto oldBack = m_back.exchange(last, std::memory_order_acq_rel);
    // Consumer can be blocked here, it doesn't see the (potentially growing)
    //  end of the queue until the next instruction.
    oldBack->next.store(first, std::memory_order_release);

    MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
    return true;
  }

  int tryRecvBatch(Enqueueable<T>** bFirst, Enqueueable<T>** bLast){
    // Try receiving all items buffered in the channel
    // Returns true if at least some items are dequeued.
    // There might be competition with producers for the last item
    //
    // Items are returned as a linked list
    // Returns the number of items received
    //
    // If no items are returned bFirst and bLast are undefined
    // and should not be used.
    //
    // ⚠️ This leaks the next item
    //   nil or overwrite it for further use in linked lists
    int result = 0;

    auto front = m_front.next.load(std::memory_order_acquire);
    *bFirst = front;
    if (front == nullptr) {
      return 0;
    }

    // Fast forward to the end of the channel
    {
      auto next = front->next.load(std::memory_order_acquire);
      while (next != nullptr) {
        result += 1;
        *bLast = front;
        front = next;
        next = next->next.load(std::memory_order_acquire);
      }
    }

    // Competing with producers at the back
    auto last = m_back.load(std::memory_order_acquire);
    if (front != last){
      // We lose the competition, bail out
      m_front.next.store(front, std::memory_order_release);
      m_count.fetch_sub(result, std::memory_order_relaxed);

      MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
      return result;
    }

    // front == last
    m_front.next.store(nullptr, std::memory_order_relaxed);
    if (m_back.compare_exchange_strong(last, &m_front, std::memory_order_acq_rel)) {
      // We won and replaced the last node with the channel front
      __builtin_prefetch(front);
      result += 1;
      m_count.fetch_sub(result, std::memory_order_acq_rel);
      *bLast = front;

      MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
      return result;
    }

    // We lost but now we know that there is an extra node coming very soon
    auto next = front->next.load(std::memory_order_acquire);
    while (next == nullptr) {
      // spinlock, livelock issue at a higher level in if the consumer never yields
      thrd_yield();
      next = front->next.load(std::memory_order_acquire);
    }

    __builtin_prefetch(front);
    result += 1;
    m_count.fetch_sub(result, std::memory_order_relaxed);
    m_front.next.store(next, std::memory_order_relaxed);
    // std::atomic_thread_fence(std::memory_order_acquire); // sync front.next.load(moRelaxed)
    *bLast = front;

    MODEL_ASSERT(m_count.load(std::memory_order_relaxed) >= 0);
    return result;

  }

};

// ----------------------------------------------------------------
// Sanity checks

struct thread_args {int ID; ChannelMpscUnboundedBatch<int>* chan;};

#define sendLoop(chan, src) \
{ \
  while (!chan->trySend(src)) ; \
}

#define recvLoop(chan, dst) \
{ \
  while (!chan->tryRecv(dst)) ; \
}

static const int NumVals = 3;
static const int Zeroes = 1000;
static const int NumSenders = 1;

void * thread_func_sender(void* args){
  struct thread_args* a = static_cast<thread_args*>(args);
  for (int i = 0; i < NumVals; ++i) {
    Enqueueable<int>* val = static_cast<Enqueueable<int>*>(malloc(sizeof(Enqueueable<int>)));
    val->payload = a->ID * Zeroes + i;
    LOG("                                0x%.08x = %d\n", val, val->payload);
    sendLoop(a->chan, val);
  }
  return nullptr;
}

void * thread_func_receiver(void* args){
  struct thread_args* a = static_cast<thread_args*>(args);
  int counts[NumSenders+1] = {0};
  for (int i = 0; i < NumSenders * NumVals; ++i){
    Enqueueable<int>* val;
    recvLoop(a->chan, &val);

    auto sender = val->payload / Zeroes;

    LOG("recv: 0x%.08x = %d\n", val, val->payload);
    MODEL_ASSERT(val->payload = counts[sender] + sender * Zeroes);

    ++counts[sender];
    free(val);
  }

  LOG("-----------------------------------\n");
  for (int sender = 1; sender < NumSenders+1; ++sender){
    LOG("counts[%d] = %d\n", sender, counts[sender]);
    MODEL_ASSERT(counts[sender] == NumVals);
  }
  return nullptr;
}

int user_main_single(int argc, char **argv){
  LOG("Running single receive test\n");

  ChannelMpscUnboundedBatch<int>* chan;
  chan = static_cast<ChannelMpscUnboundedBatch<int>*>(malloc(sizeof(ChannelMpscUnboundedBatch<int>)));
  // printf("Size channel %lu\n", sizeof(ChannelMpscUnboundedBatch<int>));
  chan->initialize();

  thrd_t thr[NumSenders+1];
  thread_args args[NumSenders+1];
  for (int i = 0; i < NumSenders+1; ++i){
    args[i].ID = i;
    args[i].chan = chan;
  }

  thrd_create(&thr[0], (thrd_start_t)&thread_func_receiver, &args[0]);
  for (int i = 1; i < NumSenders+1; ++i){
    thrd_create(&thr[i], (thrd_start_t)&thread_func_sender, &args[i]);
  }
  for (int i = 0; i < NumSenders+1; ++i){
    thrd_join(thr[i]);
  }

  free(chan);
  printf("------------------------------------------------------------------------\n");
  printf("Success\n");

  return 0;
}

// ----------------------------------------------------------------
// Batch

void * thread_func_receiver_batch(void* args){
  struct thread_args* a = static_cast<thread_args*>(args);
  int counts[NumSenders+1] = {0};
  int received = 0;
  int batchID = 0;

  while (received < NumSenders * NumVals){
    Enqueueable<int>* first;
    Enqueueable<int>* last;
    int batchSize = a->chan->tryRecvBatch(&first, &last);
    batchID += 1;
    if (batchSize == 0){
      continue;
    }

    auto cur = first;
    int idx = 0;
    while (idx < batchSize){
      auto sender = cur->payload / Zeroes;
      LOG("recv: 0x%.08x = %d\n", cur, cur->payload);
      MODEL_ASSERT(cur->payload = counts[sender] + sender * Zeroes);

      ++counts[sender];
      ++received;

      ++idx;
      if (idx == batchSize){
        MODEL_ASSERT(cur == last);
      }

      auto old = cur;
      cur = cur->next.load(std::memory_order_acq_rel);
      free(old);
      LOG("Receiver processed batch id %d of size %d (received total %d) \n", batchID, batchSize, received)
    }
  }

  LOG("-----------------------------------\n");
  for (int sender = 1; sender < NumSenders+1; ++sender){
    LOG("counts[%d] = %d\n", sender, counts[sender]);
    MODEL_ASSERT(counts[sender] == NumVals);
  }
  return nullptr;
}

int user_main_batch(int argc, char **argv){
  LOG("Running batch receive test\n");

  ChannelMpscUnboundedBatch<int>* chan;
  chan = static_cast<ChannelMpscUnboundedBatch<int>*>(malloc(sizeof(ChannelMpscUnboundedBatch<int>)));
  // printf("Size channel %lu\n", sizeof(ChannelMpscUnboundedBatch<int>));
  chan->initialize();

  thrd_t thr[NumSenders+1];
  thread_args args[NumSenders+1];
  for (int i = 0; i < NumSenders+1; ++i){
    args[i].ID = i;
    args[i].chan = chan;
  }

  thrd_create(&thr[0], (thrd_start_t)&thread_func_receiver_batch, &args[0]);
  for (int i = 1; i < NumSenders+1; ++i){
    thrd_create(&thr[i], (thrd_start_t)&thread_func_sender, &args[i]);
  }
  for (int i = 0; i < NumSenders+1; ++i){
    thrd_join(thr[i]);
  }

  free(chan);
  printf("------------------------------------------------------------------------\n");
  printf("Success\n");

  return 0;
}

int user_main(int argc, char **argv){
  user_main_single(argc, argv);
  return 0;
}
