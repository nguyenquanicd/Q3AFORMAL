$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $projectRoot 'lower-sva-alignment.q3a'
$text = & $executable --lower-project $manifest
if ($LASTEXITCODE -ne 0) {
    throw "SVA alignment manifest should lower:`n$($text -join "`n")"
}
$tir = ($text -join "`n") | ConvertFrom-Json
if ($tir.schema_version -ne 'Q3A-TIR-0.4') {
    throw "Expected Q3A-TIR-0.4 schema with split history guards; got '$($tir.schema_version)'"
}

function Find-Property([string] $name) {
    $property = @($tir.properties | Where-Object { $_.name -eq $name })[0]
    if ($null -eq $property) { throw "Missing property '$name' in lowered T-IR" }
    return $property
}

function Assert-Term($term, [string] $signal, [long] $delay, [long] $repeatMin = 1, [long] $repeatMax = 1) {
    if ($term.predicate.kind -ne 'signal' -or $term.predicate.value -ne $signal -or
        $term.delay_from_previous -ne $delay -or
        $term.repeat_min -ne $repeatMin -or $term.repeat_max -ne $repeatMax) {
        throw "Unexpected T-IR sequence term for signal '$signal'"
    }
}

function Assert-Automaton($sequence) {
    $automaton = $sequence.automaton
    $expectedStates = $sequence.terms.Count + 1
    if ($automaton.state_count -ne $expectedStates -or
        $automaton.start_state -ne 0 -or
        $automaton.accepting_state -ne ($expectedStates - 1) -or
        $automaton.transitions.Count -ne $sequence.terms.Count) {
        throw 'Sequence automaton has an invalid state count, start/accept state, or transition count'
    }
    for ($index = 0; $index -lt $sequence.terms.Count; $index++) {
        $term = $sequence.terms[$index]
        $transition = $automaton.transitions[$index]
        if ($transition.source_state -ne $index -or
            $transition.target_state -ne ($index + 1) -or
            $transition.delay_cycles -ne $term.delay_from_previous -or
            $transition.repeat_min -ne $term.repeat_min -or
            $transition.repeat_max -ne $term.repeat_max -or
            $transition.predicate.kind -ne $term.predicate.kind -or
            $transition.predicate.value -ne $term.predicate.value) {
            throw "Automaton transition $index does not preserve the reviewed sequence term"
        }
    }
}

function Find-SequenceEnds($sequence, [int] $start, [array] $samples) {
    $frontier = @($start)
    foreach ($transition in $sequence.automaton.transitions) {
        $nextFrontier = @()
        foreach ($previousEnd in $frontier) {
            $termStart = [int]$previousEnd + [int]$transition.delay_cycles
            for ($repeat = [int]$transition.repeat_min; $repeat -le [int]$transition.repeat_max; $repeat++) {
                $matches = $true
                for ($offset = 0; $offset -lt $repeat; $offset++) {
                    $sampleIndex = $termStart + $offset
                    if ($sampleIndex -ge $samples.Count -or
                        [long]$samples[$sampleIndex][$transition.predicate.value] -ne 1) {
                        $matches = $false
                        break
                    }
                }
                if ($matches) { $nextFrontier += ($termStart + $repeat - 1) }
            }
        }
        $frontier = $nextFrontier
        if ($frontier.Count -eq 0) { break }
    }
    return ,$frontier
}

function Check-Implication($property, [array] $samples) {
    $antecedent = $property.antecedent
    $maximumEndOffset = 0
    foreach ($transition in $antecedent.automaton.transitions) {
        $maximumEndOffset += [int]$transition.delay_cycles + [int]$transition.repeat_max - 1
    }
    $allObligationsHold = $true
    for ($start = 0; $start -le ($samples.Count - 1 - $maximumEndOffset); $start++) {
        foreach ($end in (Find-SequenceEnds $antecedent $start $samples)) {
            $consequentStart = [int]$end
            if ($property.implication -eq 'nonoverlapped') { $consequentStart++ }
            $ends = Find-SequenceEnds $property.consequent $consequentStart $samples
            if ($ends.Count -eq 0) { $allObligationsHold = $false }
        }
    }
    return $allObligationsHold
}

function New-Trace {
    $samples = @()
    for ($index = 0; $index -lt 8; $index++) {
        $samples += @{ a = 0; b = 0; c = 0; d = 0 }
    }
    return ,$samples
}

$overlapped = Find-Property 'p_overlapped_chain'
if ($overlapped.implication -ne 'overlapped' -or
    $overlapped.antecedent.terms.Count -ne 2 -or
    $overlapped.consequent.terms.Count -ne 2) {
    throw 'Overlapped property must retain both sequence terms on each side'
}
Assert-Term $overlapped.antecedent.terms[0] 'a' 0
Assert-Term $overlapped.antecedent.terms[1] 'b' 1
Assert-Term $overlapped.consequent.terms[0] 'c' 0
Assert-Term $overlapped.consequent.terms[1] 'd' 2
Assert-Automaton $overlapped.antecedent
Assert-Automaton $overlapped.consequent

$nonoverlapped = Find-Property 'p_nonoverlapped_chain'
if ($nonoverlapped.implication -ne 'nonoverlapped') {
    throw 'Non-overlapped implication operator was not retained'
}
Assert-Term $nonoverlapped.antecedent.terms[0] 'a' 0
Assert-Term $nonoverlapped.antecedent.terms[1] 'b' 1
Assert-Term $nonoverlapped.consequent.terms[0] 'c' 0
Assert-Term $nonoverlapped.consequent.terms[1] 'd' 2
Assert-Automaton $nonoverlapped.antecedent
Assert-Automaton $nonoverlapped.consequent

$zeroDelay = Find-Property 'p_zero_delay_chain'
if ($zeroDelay.implication -ne 'overlapped' -or
    $zeroDelay.antecedent.terms.Count -ne 2 -or
    $zeroDelay.consequent.terms.Count -ne 1) {
    throw 'Zero-delay implication must preserve both same-sample antecedent terms'
}
Assert-Term $zeroDelay.antecedent.terms[0] 'a' 0
Assert-Term $zeroDelay.antecedent.terms[1] 'b' 0
Assert-Term $zeroDelay.consequent.terms[0] 'c' 0
Assert-Automaton $zeroDelay.antecedent
Assert-Automaton $zeroDelay.consequent

$bounded = Find-Property 'p_bounded_repeat'
if ($bounded.implication -ne 'nonoverlapped' -or
    $bounded.antecedent.terms.Count -ne 1 -or
    $bounded.consequent.terms.Count -ne 1) {
    throw 'Bounded-repetition implication has an unexpected T-IR structure'
}
Assert-Term $bounded.antecedent.terms[0] 'a' 0 1 3
Assert-Term $bounded.consequent.terms[0] 'b' 0
Assert-Automaton $bounded.antecedent
Assert-Automaton $bounded.consequent

$exactRepeatCases = @(
    @{ Name = 'p_exact_repeat_one'; RepeatLength = 1 },
    @{ Name = 'p_exact_repeat_two'; RepeatLength = 2 },
    @{ Name = 'p_exact_repeat_three'; RepeatLength = 3 }
)
$equalBoundsRepeat = Find-Property 'p_equal_bounds_repeat'
foreach ($repeatCase in $exactRepeatCases) {
    $repeatProperty = Find-Property $repeatCase.Name
    if ($repeatProperty.implication -ne 'nonoverlapped' -or
        $repeatProperty.antecedent.terms.Count -ne 1 -or
        $repeatProperty.consequent.terms.Count -ne 1) {
        throw "Exact repetition property '$($repeatCase.Name)' must preserve its sequence structure"
    }
    Assert-Term $repeatProperty.antecedent.terms[0] 'a' 0 $repeatCase.RepeatLength $repeatCase.RepeatLength
    Assert-Term $repeatProperty.consequent.terms[0] 'b' 0
    Assert-Automaton $repeatProperty.antecedent
    Assert-Automaton $repeatProperty.consequent
}
if ($equalBoundsRepeat.implication -ne 'nonoverlapped' -or
    $equalBoundsRepeat.antecedent.terms.Count -ne 1 -or
    $equalBoundsRepeat.consequent.terms.Count -ne 1) {
    throw 'Equal-bound repetition property must preserve its sequence structure'
}
Assert-Term $equalBoundsRepeat.antecedent.terms[0] 'a' 0 2 2
Assert-Term $equalBoundsRepeat.consequent.terms[0] 'b' 0
Assert-Automaton $equalBoundsRepeat.antecedent
Assert-Automaton $equalBoundsRepeat.consequent

$trace = New-Trace
$trace[0].a = 1
$trace[1].b = 1
$trace[1].c = 1
$trace[3].d = 1
if (-not (Check-Implication $overlapped $trace)) {
    throw 'Overlapped implication should require c at the antecedent end and d two cycles later'
}
$trace[1].c = 0
if (Check-Implication $overlapped $trace) {
    throw 'Overlapped implication must fail when its same-end-sample consequent is absent'
}

$trace = New-Trace
$trace[0].a = 1
$trace[1].b = 1
$trace[2].c = 1
$trace[4].d = 1
if (-not (Check-Implication $nonoverlapped $trace)) {
    throw 'Non-overlapped implication should start one cycle after the antecedent end'
}
$trace[2].c = 0
if (Check-Implication $nonoverlapped $trace) {
    throw 'Non-overlapped implication must fail when its next-sample consequent is absent'
}

$trace = New-Trace
$trace[0].a = 1
$trace[0].b = 1
$trace[0].c = 1
if (-not (Check-Implication $zeroDelay $trace)) {
    throw '##0 antecedent terms and overlapped consequent must use the same sampled frame'
}
$trace[0].c = 0
if (Check-Implication $zeroDelay $trace) {
    throw '##0 implication must fail when the same-frame consequent is absent'
}
$zeroDelayBmc = & $executable --bmc $manifest --property p_zero_delay_chain --frames 0
if ($LASTEXITCODE -ne 0 -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_VACUITY NONVACUOUS' -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS COMPLETE' -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_REPLAY VALIDATED' -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=0 name=a width=1 value=0x1' -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=0 name=b width=1 value=0x1' -or
    $zeroDelayBmc -notcontains 'Q3A_BMC_TRACE_SIGNAL frame=0 name=c width=1 value=0x0') {
    throw "##0 source-to-T-IR, SAT query, and replay must find the same-frame counterexample:`n$($zeroDelayBmc -join "`n")"
}

$trace = New-Trace
foreach ($sample in 0..2) { $trace[$sample].a = 1 }
foreach ($sample in 1..3) { $trace[$sample].b = 1 }
if (-not (Check-Implication $bounded $trace)) {
    throw 'Every 1-, 2-, and 3-cycle antecedent match should launch a next-sample b obligation'
}
$trace[2].b = 0
if (Check-Implication $bounded $trace) {
    throw 'Bounded repetition must detect the consequent obligation for the two-cycle match'
}

foreach ($repeatCase in @($exactRepeatCases + @(@{ Name = 'p_equal_bounds_repeat'; RepeatLength = 2 }))) {
    $repeatProperty = Find-Property $repeatCase.Name
    $trace = New-Trace
    for ($sample = 0; $sample -lt $repeatCase.RepeatLength; $sample++) {
        $trace[$sample].a = 1
    }
    $trace[$repeatCase.RepeatLength].b = 1
    if (-not (Check-Implication $repeatProperty $trace)) {
        throw "Property '$($repeatProperty.name)' must pass for $($repeatCase.RepeatLength) consecutive a samples and next-sample b"
    }
    $trace[$repeatCase.RepeatLength].b = 0
    if (Check-Implication $repeatProperty $trace) {
        throw "Property '$($repeatProperty.name)' must fail when the next-sample b obligation is absent"
    }
}

$parameterizedManifest = Join-Path $projectRoot 'lower-sva-parameter-bounds.q3a'
$parameterizedText = & $executable --lower-project $parameterizedManifest
if ($LASTEXITCODE -ne 0) {
    throw "Parameterized SVA manifest should lower:`n$($parameterizedText -join "`n")"
}
$parameterizedTir = ($parameterizedText -join "`n") | ConvertFrom-Json
$parameterDelay = @($parameterizedTir.properties | Where-Object { $_.name -eq 'p_parameter_delay' })[0]
$parameterRepeat = @($parameterizedTir.properties | Where-Object { $_.name -eq 'p_parameter_repeat' })[0]
if ($null -eq $parameterDelay -or $null -eq $parameterRepeat -or
    $parameterDelay.antecedent.automaton.transitions[1].delay_cycles -ne 3 -or
    $parameterRepeat.antecedent.automaton.transitions[0].repeat_min -ne 4 -or
    $parameterRepeat.antecedent.automaton.transitions[0].repeat_max -ne 4) {
    throw 'Automaton transitions must contain resolved parameter values for delay and exact repetition'
}
Assert-Automaton $parameterDelay.antecedent
Assert-Automaton $parameterRepeat.antecedent

$compoundManifest = Join-Path $projectRoot 'lower-sva-compound-exact-repeat.q3a'
$compoundText = @(& $executable --lower-project $compoundManifest)
if ($LASTEXITCODE -ne 0) {
    throw "Exact compound repetition failed to lower:`n$($compoundText -join "`n")"
}
$compound = ($compoundText -join "`n") | ConvertFrom-Json
foreach ($shape in @(
    @{ Name = 'c_prefixed'; Delays = '0,2,2,1,2'; Predicates = 'start,a,b,a,b' },
    @{ Name = 'p_guarded'; Delays = '0,0,1,0'; Predicates = 'a,b,a,b' },
    @{ Name = 'p_nested'; Delays = '0,0,1,0,1,0,1,0'; Predicates = $null }
)) {
    $property = $compound.properties | Where-Object name -CEQ $shape.Name
    Assert-Automaton $property.antecedent
    $transitions = @($property.antecedent.automaton.transitions)
    if (($transitions.delay_cycles -join ',') -ne $shape.Delays -or
        ($shape.Predicates -and ($transitions.predicate.value -join ',') -ne $shape.Predicates)) {
        throw "Incorrect inter- or intra-iteration delay for $($shape.Name)."
    }
}
foreach ($query in @(
    @{ Name = 'c_prefixed'; Frames = 6; Status = 'UNKNOWN' },
    @{ Name = 'c_prefixed'; Frames = 7; Status = 'COVERED'; Replay = $true },
    @{ Name = 'p_guarded'; Frames = 1; Status = 'BOUNDED_PASS' },
    @{ Name = 'p_wrong'; Frames = 1; Status = 'BOUNDED_FAIL'; Replay = $true },
    @{ Name = 'p_nested'; Frames = 3; Status = 'BOUNDED_PASS' },
    @{ Name = 'c_ranged'; Frames = 2; Status = 'UNKNOWN' },
    @{ Name = 'c_ranged'; Frames = 3; Status = 'COVERED'; Replay = $true },
    @{ Name = 'c_nested_ranged'; Frames = 1; Status = 'COVERED'; Replay = $true },
    @{ Name = 'p_range_wrong'; Frames = 2; Status = 'BOUNDED_FAIL'; Replay = $true },
    @{ Name = 'p_range_consequent'; Frames = 2; Status = 'BOUNDED_PASS' }
)) {
    $output = @(& $executable --bmc $compoundManifest --property $query.Name --frames $query.Frames)
    if ($LASTEXITCODE -ne 0 -or $output -notcontains "Q3A_BMC_STATUS $($query.Status)" -or
        ($query.Replay -and $output -notcontains 'Q3A_BMC_REPLAY VALIDATED')) {
        throw "Incorrect exact compound repetition result at $($query.Frames) transitions:`n$($output -join "`n")"
    }
}
$ranged = ($compound.properties | Where-Object name -CEQ 'c_ranged').antecedent.automaton
$branchDelays = @()
$currentDelays = @()
foreach ($edge in $ranged.transitions) {
    $currentDelays += $edge.delay_cycles
    if ($edge.target_state -eq $ranged.accepting_state) {
        $branchDelays += ($currentDelays -join ',')
        $currentDelays = @()
    }
}
if (($branchDelays -join '|') -ne '0,1,1,1|0,1,1,1,1,1|0,1,1,1,1,1,1,1') {
    throw "Incorrect ranged repetition and suffix timing: $branchDelays"
}
$nestedRange = ($compound.properties | Where-Object name -CEQ 'c_nested_ranged').antecedent.automaton
$nestedEndpoints = @()
$offset = 0
foreach ($edge in $nestedRange.transitions) {
    $offset += $edge.delay_cycles
    if ($edge.target_state -eq $nestedRange.accepting_state) {
        $nestedEndpoints += $offset
        $offset = 0
    }
}
if (($nestedEndpoints -join ',') -ne '1,2,2,3') {
    throw "Nested repeats did not independently choose the inner repetition count: $nestedEndpoints"
}
$limitManifest = Join-Path $projectRoot 'reject-sva-compound-repeat-limit.q3a'
$limit = @(& $executable --lower-project $limitManifest 2>&1)
if ($LASTEXITCODE -ne 1 -or ($limit -join "`n") -notmatch
    'sva_compound_repeat_limit\.sv:2:\d+: compound repetition exceeds the lowered SVA term limit of 10000') {
    throw "Oversized expansion did not produce its source-located limit: $limit"
}

'PASS: implication timing, parameter bounds, exact compound repeat offsets and nested repeats, history-aware counterexample replay, and source-located expansion limits.'
