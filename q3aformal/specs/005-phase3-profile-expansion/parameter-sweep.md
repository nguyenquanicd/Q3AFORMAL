# Q3AFormal Parameter Sweep Contract

A version 3 batch plan specifies named configurations in execution order. Each job can add one or more `param NAME VALUE` entries. The values use the existing proof command's parameter syntax.

```text
Q3AFORMAL_BATCH 3
memory_mib 768
job fixed induction p_hold 2 30000 param DROP_STALL 0
job faulty bmc p_hold 8 30000 param DROP_STALL 1
job project-default bmc p_hold 8 30000
```

The runner applies the listed assignments to a copy of the source configuration already admitted for the batch. Values supplied for the job replace the corresponding manifest values. All other assignments retain their manifest settings or the RTL defaults. An invalid parameter configuration returns a job-level diagnostic. Subsequent jobs retain their own plan assignments.

Reports retain declared overrides for each point and capture effective parameters for resolved proof configurations. The resolved source identity includes the parameter map. Evidence revalidation recreates the same point before checking its proof or witness. Checkpoints bind the exact plan, original manifest, base source set and build. A source-identical project with a different declared sweep uses a separate checkpoint run.

Use the regular `prove-batch` command, with optional checkpoint, resume and Windows workers. Versions 1 and 2 preserve their existing formats. Terminal job results retain their normal semantics. For example, a checked counterexample and a checked proof can both appear in a completed batch. For unbounded proof coverage, every required point must separately report `PROVEN`.

The sweep covers the configurations listed in the plan. The claim is scoped to those assignments and selected properties.

## Windows qualification

Five batch points ran in both serial and parallel modes. Bounded Model Checking (BMC), k-induction, and Property Directed Reachability (PDR) kept their individual proof or failure statuses. The two modes reopened all ten points from their effective parameter settings. A separate two-parameter fixture reopened another two points. A parameter inherited from the manifest matched the same value listed explicitly. Wrong-point evidence failed revalidation even after its checkpoint digest was refreshed. A job with an unknown top-level parameter returned an elaboration diagnostic while its successor proved. The standalone checker accepted all ten proof obligations across both execution modes. Previous batch versions and the five Phase 2 functional workloads also passed. [Integration test](test_parameter_sweep.ps1) · [Qualification](../../evidence/r-p3-sweep/qualification.json) · [Standalone evidence](../../evidence/r-p3-sweep/standalone-proofs.json)
