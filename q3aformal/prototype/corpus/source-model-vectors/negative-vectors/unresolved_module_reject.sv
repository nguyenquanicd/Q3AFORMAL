module unresolved_module_reject (
    input  logic a,
    output logic y
);
    phase0_missing_child u_child (
        .a(a),
        .y(y)
    );
endmodule
