// Two masters, one slave, selected by a level. Not an arbiter.
//
// `k2g_psram` already arbitrates between fetch and data, cycle by cycle, and
// this is a different thing: OWNERSHIP. The boot copier owns the data port
// while the machine is booting and the core owns it afterwards, and the two are
// never live at once because the core is held in reset for the whole copy.
//
// WHAT MAKES IT SAFE, and it is a property of the users rather than of this
// module: `sel` may only move when nothing is in flight. A write produces no
// response (k2g_membus.sv), the copier issues nothing else, and the core has
// not left reset, so at the moment `sel` changes there is no response owed to
// either side and none can be misrouted. Switch it under any other condition
// and a response goes to the master that did not ask for it -- which for the
// core means an `issue_addr` queue one entry out of step, forever.
//
// A general version would count outstanding requests per master and hold the
// switch until the count reaches zero. That is worth writing when something
// actually needs to hand the bus over mid-run; nothing here does.

module k2g_membus_mux (
    input logic sel,            // 0 = up_a owns the bus, 1 = up_b

    k2g_membus.slave  up_a,
    k2g_membus.slave  up_b,
    k2g_membus.master down
);

  assign down.req_valid = sel ? up_b.req_valid : up_a.req_valid;
  assign down.req       = sel ? up_b.req       : up_a.req;

  assign up_a.req_ready = !sel && down.req_ready;
  assign up_b.req_ready =  sel && down.req_ready;

  assign up_a.rsp_valid = !sel && down.rsp_valid;
  assign up_b.rsp_valid =  sel && down.rsp_valid;
  assign up_a.rsp_data  = down.rsp_data;
  assign up_b.rsp_data  = down.rsp_data;

endmodule
