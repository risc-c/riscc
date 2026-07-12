`default_nettype none

// Agilex 3 configuration-reset endpoint. Quartus recognizes this documented
// device primitive directly; no generated reset-release IP wrapper is needed.
module atum_reset_release (
    output wire ninit_done
);
    altera_agilex_config_reset_release_endpoint endpoint (
        .conf_reset(ninit_done)
    );
endmodule

`default_nettype wire
