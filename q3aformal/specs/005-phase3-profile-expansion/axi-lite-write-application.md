# AXI4-Lite write-channel formal application

This Phase 3 application exercises the write portion of the Advanced Microcontroller Bus Architecture (AMBA) Advanced eXtensible Interface (AXI) AXI4-Lite protocol. The Register-Transfer Level (RTL) fixture accepts independent address and data, pairs them in order, applies four byte strobes to a 32-bit write, and returns one response. The proof models address, data, and response handshakes as transfers at positive clock edges. [Arm AMBA AXI and ACE Protocol Specification, IHI 0022H, parts A3 and B1](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)

## Scope and proof

The fixture has two word-aligned locations, `0x0` and `0x4`, a four-bit address, an active-high synchronous fixture reset, and capacity for one outstanding response. The model covers the specified write paths. Read channels, protection bits, clock crossings, and multiple outstanding responses are outside this fixture's interface. The response for an unmapped location is `DECERR` (decode error), while a mapped location returns `OKAY`. A mapped write with all strobes clear preserves the register.

The independent scoreboard collects accepted channel items from interface handshakes. It retains those items until the expected response retires and updates the selected reference byte when the pair completes. The formal harness observes private DUT state only in the relational invariant. The master assumptions require valid and payload to remain stable during address or data stalls outside reset. The receiver's write-response ready signal can stay low arbitrarily long.

Register and observation state is initially unconstrained. The reset property establishes the control and selected-byte correspondence. The control and byte step properties preserve that correspondence across each following non-reset transition. Together, the reset and step proofs cover all post-reset samples. Four parameter configurations cover all byte lanes. A separate assertion checks valid and response-code stability during a stalled response.

The cover goals require observable transactions for address-first, data-first, simultaneous inputs, two cycles of backpressure, an unmapped address, and a zero-strobe write. Three intentionally faulty configurations exercise early response, ignored high-byte strobe, and a dropped stalled response.

## Run on Windows

From the Q3AFormal workspace, provide the engine and standalone checker from the same extracted package.

```powershell
& .\specs\005-phase3-profile-expansion\test_axi_lite_write.ps1 `
    -ExecutablePath .\prototype\bin\q3aformal-sourcecheck.exe `
    -CheckerPath .\prototype\bin\q3aformal-proofcheck.exe `
    -OutputDirectory evidence\axi-lite-write-local
```

Each successful Property Directed Reachability (PDR) run is reopened from the effective project and parameter set. The independent checker separately validates Deletion Resolution Asymmetric Tautology (DRAT) obligations for control and the highest byte lane. Each cover or mutation outcome is saved and checked against the archived source model. [Manifest and source](axi-lite/write.q3a) · [Regression](test_axi_lite_write.ps1)

## Windows qualification

The revision 2 development package produced ten source-revalidated proofs, including reset and transition checks for every byte. The standalone checker accepted six obligations. All six coverage witnesses and three injected-fault counterexamples independently replayed. This qualification identifies the exact engines, fixture bytes, property results, and parameters. [Qualification](../../evidence/p3-axi-lite-write/qualification.json) · [Extracted package identity](../../evidence/p23-compact-archive-qualification/qualification.json)
