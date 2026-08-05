// -------------------------------------------------------------------------
// GENERATED FILE -- DO NOT EDIT BY HAND.
//
// Produced by emu/src/hostproto.rs, which is the single definition of the
// host-control wire protocol. The `kctl` host tool and rtl/k2g_mon.sv both
// take their type codes from it, so they cannot disagree about what a
// frame means.
//
// Regenerate:  cd emu && cargo run --bin gen_defs
// Verify:      cd emu && cargo test  (golden-file test fails on drift)
// -------------------------------------------------------------------------

`ifndef K2G_HOST_PKG_SV
`define K2G_HOST_PKG_SV

package k2g_host_pkg;

  // ---- framing -----------------------------------------------------------
  // magic(2) | type(1) | len(2, LE) | payload | crc16(2, LE)
  // The CRC covers type, len and payload -- not the magic, which is a
  // delimiter rather than data.
  localparam logic [7:0] MAGIC0 = 8'h1B;
  localparam logic [7:0] MAGIC1 = 8'h4B;
  localparam int PROTO_VERSION = 1;
  localparam int MAX_PAYLOAD   = 128;
  localparam int LEN_W         = 8;

  localparam logic [15:0] CRC_INIT = 16'hFFFF;
  localparam logic [15:0] CRC_POLY = 16'h1021;

  // ---- frame types -------------------------------------------------------
  // Host-to-board codes are 0x0x; board-to-host codes have the top bit set.
  typedef enum logic [7:0] {
    HF_PING        = 8'h01,  // none
    HF_STATUS      = 8'h02,  // none
    HF_PAUSE       = 8'h03,  // none
    HF_RESUME      = 8'h04,  // none
    HF_RESET       = 8'h05,  // none
    HF_WRITE       = 8'h06,  // addr u32 LE, then the bytes
    HF_READ        = 8'h07,  // addr u32 LE, count u16 LE
    HF_CONSOLE_IN  = 8'h08,  // the bytes
    HF_IDENT       = 8'h81,  // version u16, max_payload u16, core_id u32, mem_bytes u32, caps u32
    HF_STATE       = 8'h82,  // flags u8, fault_cause u8, rsvd u16, fault_addr u32, fault_info u32, cycles u64
    HF_ACK         = 8'h83,  // count u16 LE
    HF_DATA        = 8'h84,  // the bytes
    HF_NAK         = 8'h8E,  // reason u8
    HF_CONSOLE_OUT = 8'h8F   // the bytes
  } host_frame_e;

  // ---- NAK reasons -------------------------------------------------------
  typedef enum logic [7:0] {
    NAK_CRC     = 8'h01,
    NAK_TYPE    = 8'h02,
    NAK_LENGTH  = 8'h03,
    NAK_ADDRESS = 8'h04,
    NAK_STATE   = 8'h05,
    NAK_BUSY    = 8'h06
  } nak_reason_e;

  // ---- payload layouts ---------------------------------------------------
  localparam int IDENT_LEN     = 16;
  localparam int STATE_LEN     = 20;
  localparam int ACK_LEN       = 2;
  localparam int NAK_LEN       = 1;
  localparam int READ_REQ_LEN  = 6;
  localparam int WRITE_HDR_LEN = 4;

  localparam logic [7:0] FLAG_PAUSED    = 8'h01;
  localparam logic [7:0] FLAG_HALTED    = 8'h02;
  localparam logic [7:0] FLAG_FAULTED   = 8'h04;
  localparam logic [7:0] FLAG_BUS_OWNED = 8'h08;

  localparam logic [31:0] CAP_MEMORY      = 32'h00000001;
  localparam logic [31:0] CAP_RUN_CONTROL = 32'h00000002;
  localparam logic [31:0] CAP_CONSOLE     = 32'h00000004;
  localparam logic [31:0] CAP_CONSOLE_IN  = 32'h00000008;

  localparam logic [31:0] CORE_ID = 32'h4B324731;

endpackage

`endif  // K2G_HOST_PKG_SV
