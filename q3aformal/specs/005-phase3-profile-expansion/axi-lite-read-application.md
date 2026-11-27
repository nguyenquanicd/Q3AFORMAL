# AXI4-Lite read-channel formal application

This Phase 3 fixture exercises the read address and read data channels of the Advanced Microcontroller Bus Architecture (AMBA) Advanced eXtensible Interface (AXI) AXI4-Lite protocol. The Register-Transfer Level (RTL) fixture accepts an address when both address handshake signals are high at a rising clock edge. It holds the response valid, data, and code until the receiver accepts them, except when the synchronous fixture reset clears the outstanding transaction. [Arm AMBA AXI and ACE Protocol Specification, IHI 0022H, sections A3.2.2 and B1](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)

## Proof scope

The fixture accepts a four-bit address and has capacity for one outstanding 32-bit response. Addresses `0x0` and `0x4` select independently changing backing words. The read samples the selected word at address acceptance. An unmapped address returns zero data with `DECERR` (decode error). The fixture starts the next request on a later edge after the preceding response retires.

The independent scoreboard observes address and response handshakes and records one reference byte at a time. A reset obligation establishes its correspondence with the device under test, and the control and byte-step obligations preserve that correspondence across non-reset transitions. Four parameter configurations cover every byte. Four separate response-hold checks cover data stability for every byte as well as valid and response-code stability. The only traffic assumption requires the requester to retain its address and valid signal when stalled outside reset. The response receiver and backing words are unconstrained.

Four cover goals exercise both mapped words, an unmapped address, and a stalled second request that is subsequently accepted while the backing input changes during the first response. Three faulty configurations test a lost high byte, an unmapped address returning `OKAY`, and a dropped stalled response. This fixture covers the read side with independently driven backing data. The separate write application verifies byte strobes and write-channel pairing. A shared register bank, simultaneous read and write arbitration, and multiple outstanding reads are outside the fixture. [Write application](axi-lite-write-application.md)

## Run on Windows

From the Q3AFormal workspace, supply the executable and standalone checker from the extracted Windows package. The script creates the requested evidence directory.

```powershell
& .\specs\005-phase3-profile-expansion\test_axi_lite_read.ps1 `
    -ExecutablePath .\prototype\bin\q3aformal-sourcecheck.exe `
    -CheckerPath .\prototype\bin\q3aformal-proofcheck.exe `
    -OutputDirectory evidence\axi-lite-read-local
```

Preview r3 produced ten source-revalidated Property Directed Reachability (PDR) proofs. The standalone checker accepted six Deletion Resolution Asymmetric Tautology (DRAT) obligations for the control relation and highest byte. The formal engine reopened the four cover witnesses and all three counterexamples by regenerating the original model from the archived RTL. [Fixture manifest](axi-lite/read.q3a) · [Test script](test_axi_lite_read.ps1) · [Windows qualification](../../evidence/p3-axi-read/qualification.json)
