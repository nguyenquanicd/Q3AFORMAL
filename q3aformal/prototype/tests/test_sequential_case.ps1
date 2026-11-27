$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-sequential-case.q3a'

$tirText = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Sequential case vector failed to lower: $($tirText -join "`n")"
}
$tir = ($tirText -join "`n") | ConvertFrom-Json
if ($tir.next_state_equations.Count -ne 1) {
    throw "Expected one state update equation, got $($tir.next_state_equations.Count)"
}

$equation = $tir.next_state_equations[0].expression
if ($equation.kind -ne 'conditional' -or $equation.operands[0].value -ne '==') {
    throw 'Expected an exact-case priority mux in the next-state expression'
}
if ($equation.operands[1].kind -ne 'signal' -or
    $equation.operands[1].value -ne 'value_b') {
    throw 'The last nonblocking assignment in the first case arm must win'
}
if ($equation.operands[2].kind -ne 'conditional' -or
    $equation.operands[2].operands[0].value -ne '||') {
    throw 'Multiple case labels must combine into one match condition'
}

'PASS: sequential case priority and last-nonblocking-assignment semantics are lowered.'
