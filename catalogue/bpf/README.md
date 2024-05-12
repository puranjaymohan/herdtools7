# Litmus Tests for BPF Memory model
Author: Puranjay Mohan <puranjay@kernel.org>
## Introduction

This README will explain the current status of BPF support in herd7. It explains how some of the litmus tests can be run using herd7 and BPF assembly. the test/ directory has some litmus tests ported from the linux kernel.
### BPF ISA support in herd7
In the current state, herd7 supports the following BPF instructions:

#### Data movement instructions
1. Register to Register
```
r0 = r5
```
2. Immediate to Register
```
r3 = 40
```

#### Arithemetic and Logical Instructions
The meanings of these symbols are self explainatory. They match the C style operators.
1. Register to Register
```
r0 += r1
r2 -= r3
r3 *= r5
r2 /= r5
r4 %= r6
r8 &= r7
r1 |= r6
r4 ^= r4
r4 <<= r5
r3 >>= r4
```
2. Immediate to Register
```
r0 += 5
r2 -= 33
r3 *= 44
r2 /= -2
r4 %= 3
[...]
Continues like register to register
```
#### Load / Store Instructions
The current support of BPF in herd7 doesn't include mixed sized operations, so all these Loads and Stores are fixed at 32-bits. You may use any size in the litmus tests, but the operations are implemented as 32-bit loads and stores.
1. Load Register
```
r0 = *(u8 *)(r0 + 0)
r2 = *(u16 *)(r4 + 0)
r4 = *(u32 *)(r5 + 0)
r5 = *(u64 *)(r6 + 0)
```
2. Store Register
```
*(u8 *)(r0 + 0)  =  r0
*(u16 *)(r4 + 0) =  r2
*(u32 *)(r5 + 0) =  r4
*(u64 *)(r6 + 0) =  r5

```
3. Store Immediate
```
*(u8 *)(r0 + 0)  = 23
*(u16 *)(r4 + 0) = -32
*(u32 *)(r5 + 0) = 44
*(u64 *)(r6 + 0) = 55
```
#### Atomic Instructions

1. 32 and 64 bit atomic operations:
These instructions do an ALU op to a memory location (register + offset) atomically. It can work with 32-bit and 64-bit data.
```
lock *(u32 *)(rd + offset16) += rs
lock *(u32 *)(rd + offset16) &= rs
lock *(u32 *)(rd + offset16) |= rs
lock *(u32 *)(rd + offset16) ^= rs

lock *(u64 *)(rd + offset16) += rs
lock *(u64 *)(rd + offset16) &= rs
lock *(u64 *)(rd + offset16) |= rs
lock *(u64 *)(rd + offset16) ^= rs
```

2. 32 and 64 bit atomic operations with fetch:
These instructions fetch the value from memory and then do an ALU op on the memory location (register + offset) atomically. It can work with 32-bit and 64-bit data.
```
rs = atomic_fetch_add ((u32 *)(rd + offset16), rs)
rs = atomic_fetch_and ((u32 *)(rd + offset16), rs)
rs = atomic_fetch_aor ((u32 *)(rd + offset16), rs)
rs = atomic_fetch_xor ((u32 *)(rd + offset16), rs)

rs = atomic_fetch_add ((u64 *)(rd + offset16), rs)
rs = atomic_fetch_and ((u64 *)(rd + offset16), rs)
rs = atomic_fetch_aor ((u64 *)(rd + offset16), rs)
rs = atomic_fetch_xor ((u64 *)(rd + offset16), rs)
```

3. Atomic exchange instruction 32 and 64 bit
This instruction atomically exchanges the value in a register rs with the value addressed by rd + offset
```
rs = xchg_64 (rd + offset16, rs)
rs = xchg_32 (rd + offset16, rs)
```

####  Barrier / Fence instruction
BPF doesn't have a real sync instruction. BPF atomic instructions with fetch provide full ordering as enforced by `bpf_lkmm.cat`. So, we a atomic op with fetch to enforce ordering in the programs.
```
r6 = atomic_fetch_add((u64*)(r5 + 0), r6)
```
### Provided cat models
The default model for BPF is the weakest available model, so if you run a litmus test like:
```
/usr/local/bin/herd7 SB+poonceonces.litmus
```
This will use the weak model.

There is another model called `bpf_lkmm.cat` that is under development but provides semantics that are closer to LKMM.
It can be used like:
```
/usr/local/bin/herd7 -model bpf_lkmm.cat SB+poonceonces.litmus
```
## Running Litmus Tests

#### Compiling and installing herd
From the root directory of herdtools7 run:
```
make PREFIX=/usr/local
sudo make PREFIX=/usr/local install
```

### Launch herd7 and run tests
The tests directory with this README.md has some litmus tests, let's run them using both the default weak model and the `bpf_lkmm.cat`

#### CoRR+poonceonce+Once.litmus [Verifies R -> R from same address should be ordered ]
```
cd herdtools7/catalogue/bpf/tests

/usr/local/bin/herd7 CoRR+poonceonce+Once.litmus
Test CoRR+poonceonce+Once Allowed
States 4
1:r1=0; 1:r2=0;
1:r1=0; 1:r2=1;
1:r1=1; 1:r2=0;
1:r1=1; 1:r2=1;
Ok
Witnesses
Positive: 1 Negative: 3
Condition exists (1:r1=1 /\ 1:r2=0)
Observation CoRR+poonceonce+Once Sometimes 1 3
Time CoRR+poonceonce+Once 0.00
Hash=1046c07e495c24483978cd17c36e4d31
```
The above run used the default model that is very weak. The result `Sometimes` is wrong as according to LKMM, this test should say `NEVER`.
Now let's try to run this with `bpf_lkmm.cat` model:
```
/usr/local/bin/herd7 -model bpf_lkmm.cat CoRR+poonceonce+Once.litmus
Test CoRR+poonceonce+Once Allowed
States 3
1:r1=0; 1:r2=0;
1:r1=0; 1:r2=1;
1:r1=1; 1:r2=1;
No
Witnesses
Positive: 0 Negative: 3
Condition exists (1:r1=1 /\ 1:r2=0)
Observation CoRR+poonceonce+Once Never 0 3
Time CoRR+poonceonce+Once 0.00
Hash=1046c07e495c24483978cd17c36e4d31
```
As we see, now this says `NEVER` which is correct according to LKMM.

#### IRIW+poonceonces+OnceOnce [Allowed by LKMM]
```
/usr/local/bin/herd7 -model bpf_lkmm.cat IRIW+poonceonces+OnceOnce.litmus
Test IRIW+poonceonces+OnceOnce Allowed
States 16
1:r2=0; 1:r3=0; 3:r2=0; 3:r3=0;
1:r2=0; 1:r3=0; 3:r2=0; 3:r3=1;
1:r2=0; 1:r3=0; 3:r2=1; 3:r3=0;
1:r2=0; 1:r3=0; 3:r2=1; 3:r3=1;
1:r2=0; 1:r3=1; 3:r2=0; 3:r3=0;
1:r2=0; 1:r3=1; 3:r2=0; 3:r3=1;
1:r2=0; 1:r3=1; 3:r2=1; 3:r3=0;
1:r2=0; 1:r3=1; 3:r2=1; 3:r3=1;
1:r2=1; 1:r3=0; 3:r2=0; 3:r3=0;
1:r2=1; 1:r3=0; 3:r2=0; 3:r3=1;
1:r2=1; 1:r3=0; 3:r2=1; 3:r3=0;
1:r2=1; 1:r3=0; 3:r2=1; 3:r3=1;
1:r2=1; 1:r3=1; 3:r2=0; 3:r3=0;
1:r2=1; 1:r3=1; 3:r2=0; 3:r3=1;
1:r2=1; 1:r3=1; 3:r2=1; 3:r3=0;
1:r2=1; 1:r3=1; 3:r2=1; 3:r3=1;
Ok
Witnesses
Positive: 1 Negative: 15
Condition exists (1:r2=1 /\ 1:r3=0 /\ 3:r2=1 /\ 3:r3=0)
Observation IRIW+poonceonces+OnceOnce Sometimes 1 15
Time IRIW+poonceonces+OnceOnce 0.01
Hash=dc3f0f1510ace4b9a3cc9d1128afbe8c
```
Here we see `Sometimes`, this is allowed by LKMM.

#### IRIW+fencembonceonces+OnceOnce [Not Allowed]
Now, fences/barriers are in place, so it should say `Never`
```
/usr/local/bin/herd7 -model bpf_lkmm.cat IRIW+fencembonceonces+OnceOnce.litmus
Test IRIW+fencembonceonces+OnceOnce Allowed
States 15
1:r2=0; 1:r3=0; 3:r2=0; 3:r3=0;
1:r2=0; 1:r3=0; 3:r2=0; 3:r3=1;
1:r2=0; 1:r3=0; 3:r2=1; 3:r3=0;
1:r2=0; 1:r3=0; 3:r2=1; 3:r3=1;
1:r2=0; 1:r3=1; 3:r2=0; 3:r3=0;
1:r2=0; 1:r3=1; 3:r2=0; 3:r3=1;
1:r2=0; 1:r3=1; 3:r2=1; 3:r3=0;
1:r2=0; 1:r3=1; 3:r2=1; 3:r3=1;
1:r2=1; 1:r3=0; 3:r2=0; 3:r3=0;
1:r2=1; 1:r3=0; 3:r2=0; 3:r3=1;
1:r2=1; 1:r3=0; 3:r2=1; 3:r3=1;
1:r2=1; 1:r3=1; 3:r2=0; 3:r3=0;
1:r2=1; 1:r3=1; 3:r2=0; 3:r3=1;
1:r2=1; 1:r3=1; 3:r2=1; 3:r3=0;
1:r2=1; 1:r3=1; 3:r2=1; 3:r3=1;
No
Witnesses
Positive: 0 Negative: 15
Condition exists (1:r2=1 /\ 1:r3=0 /\ 3:r2=1 /\ 3:r3=0)
Observation IRIW+fencembonceonces+OnceOnce Never 0 15
Time IRIW+fencembonceonces+OnceOnce 0.01
Hash=cb55ae2e831237cb295221a97bf9a6b0
```


This says `Never` which is the correct outcome.

###### Please try other tests in the directory. I will keep adding more.

###### NOTE 1:
Always run the tests with `-model bpf_lkmm.cat` unless you are doing some experimentation. The default model is very minimal and basically allows everything.

###### Note 2:
bpf_lkmm.cat is not perfect, it might fail for some LKMM tests, but we are working on improving it.
