module recursive_instance_reject (
    input  logic a,
    output logic y
);
    recursive_instance_reject u_recurse (
        .a(a),
        .y(y)
    );
endmodule
