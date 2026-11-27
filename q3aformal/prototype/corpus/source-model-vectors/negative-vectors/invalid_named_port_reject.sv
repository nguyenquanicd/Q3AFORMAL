module invalid_named_port_reject (
    input  logic a,
    output logic y
);
    hierarchy_leaf u_compare (
        .invalid_port(a),
        .equal(y)
    );
endmodule
