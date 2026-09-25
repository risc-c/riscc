// agilex3_reset_release.v : Agilex configuration-reset primitive wrapper.

`default_nettype none

// The board build generates the catalog Reset Release IP before synthesis.
module agilex3_reset_release (
    output wire ninit_done
);
    agilex3_config_reset endpoint (
        .ninit_done(ninit_done)
    );
endmodule

`default_nettype wire
