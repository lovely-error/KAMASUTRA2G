
typedef enum bit [5:0] {

  LB_EP1 = 'b111111, // 63
  LB_ADD = 'b111110, // 62
  LB_SUB = 'b111101, // 61
  LB_MUL = 'b111100, // 60
  LB_DIV = 'b111011, // 59
  LB_AND = 'b111010, // 58
  LB_OR = 'b111001, // 57
  LB_TST = 'b111000, // 56

  LB_XOR = 'b110111, // 55
  LB_XC = 'b110110, // 54
  LB_GTE = 'b110101, // 53
  LB_SHRA = 'b110100, // 52
  LB_LD8 = 'b110011, // 51
  LB_LD16 = 'b110010, // 50
  LB_LD32 = 'b110001, // 49
  LB_LDF32 = 'b110000, // 48

  LB_SHL = 'b101111, // 47
  LB_DISP = 'b101110, // 46
  LB_DISPI = 'b101101, // 45
  LB_ST = 'b101100, // 44
  LB_CPY = 'b101011, // 43
  LB_XI = 'b101010, // 42
  LB_PUC = 'b101001, // 41
  LB_TSTN = 'b101000, // 40

  LB_SHR = 'b100111, // 39
  LB_LT = 'b100110, // 38
  LB_LTE = 'b100101, // 37
  LB_GT = 'b100100, // 36
  LB_GTE = 'b100011, // 35
  LB_XCN = 'b100010, // 34
  LB_XCP = 'b100001, // 33
  LB_UNCLAIMED_32 = 'b100000, // 32

  LB_UNCLAIMED_31 = 'b011111, // 31
  LB_UNCLAIMED_30 = 'b011110, // 30
  LB_UNCLAIMED_29 = 'b011101, // 29
  LB_UNCLAIMED_28 = 'b011100, // 28
  LB_UNCLAIMED_27 = 'b011011, // 27
  LB_UNCLAIMED_26 = 'b011010, // 26
  LB_UNCLAIMED_25 = 'b011001, // 25
  LB_UNCLAIMED_24 = 'b011000, // 24

  LB_UNCLAIMED_23 = 'b010111, // 23
  LB_UNCLAIMED_22 = 'b010110, // 22
  LB_UNCLAIMED_21 = 'b010101, // 21
  LB_UNCLAIMED_20 = 'b010100, // 20
  LB_UNCLAIMED_19 = 'b010011, // 19
  LB_UNCLAIMED_18 = 'b010010, // 18
  LB_UNCLAIMED_17 = 'b010001, // 17
  LB_UNCLAIMED_16 = 'b010000, // 16

  LB_UNCLAIMED_15 = 'b001111, // 15
  LB_UNCLAIMED_14 = 'b001110, // 14
  LB_UNCLAIMED_13 = 'b001101, // 13
  LB_UNCLAIMED_12 = 'b001100, // 12
  LB_UNCLAIMED_11 = 'b001011, // 11
  LB_UNCLAIMED_10 = 'b001010, // 10
  LB_UNCLAIMED_9 = 'b001001, // 9
  LB_UNCLAIMED_8 = 'b001000, // 8

  LB_UNCLAIMED_7 = 'b000111, // 7
  LB_UNCLAIMED_6 = 'b000110, // 6
  LB_UNCLAIMED_5 = 'b000101, // 5
  LB_UNCLAIMED_4 = 'b000100, // 4
  LB_UNCLAIMED_3 = 'b000011, // 3
  LB_UNCLAIMED_2 = 'b000010, // 2
  LB_UNCLAIMED_1 = 'b000001, // 1
  LB_UNCLAIMED_0 = 'b000000 // 0

} LB ;

typedef enum bit [4:0] {

  EP1_EP2 = 'b11111, // 31
  EP1_LINK = 'b11110, // 30
  EP1_MULW = 'b11101, // 29
  EP1_MV = 'b11100, // 28
  EP1_SS = 'b11011, // 27
  EP1_NOT = 'b11010, // 26
  EP1_IW = 'b11001, // 25
  EP1_NEG = 'b11000, // 24

  EP1_DISP_OFF = 'b10111, // 23
  EP1_DISP_ABS = 'b10110, // 22
  EP1_SR = 'b10101, // 21
  EP1_SSS = 'b10100, // 20
  EP1_UNCLAIMED_19 = 'b10011, // 19
  EP1_UNCLAIMED_18 = 'b10010, // 18
  EP1_UNCLAIMED_17 = 'b10001, // 17
  EP1_UNCLAIMED_16 = 'b10000, // 16

  EP1_UNCLAIMED_15 = 'b01111, // 15
  EP1_UNCLAIMED_14 = 'b01110, // 14
  EP1_UNCLAIMED_13 = 'b01101, // 13
  EP1_UNCLAIMED_12 = 'b01100, // 12
  EP1_UNCLAIMED_11 = 'b01011, // 11
  EP1_UNCLAIMED_10 = 'b01010, // 10
  EP1_UNCLAIMED_9 = 'b01001, // 9
  EP1_UNCLAIMED_8 = 'b01000, // 8

  EP1_UNCLAIMED_7 = 'b00111, // 7
  EP1_UNCLAIMED_6 = 'b00110, // 6
  EP1_UNCLAIMED_5 = 'b00101, // 5
  EP1_UNCLAIMED_4 = 'b00100, // 4
  EP1_UNCLAIMED_3 = 'b00011, // 3
  EP1_UNCLAIMED_2 = 'b00010, // 2
  EP1_UNCLAIMED_1 = 'b00001, // 1
  EP1_UNCLAIMED_0 = 'b00000 // 0

} EP1 ;

typedef enum bit [4:0] {

  EP2_FLAG = 'b11111, // 31
  EP2_CSP = 'b11110, // 30
  EP2_TC = 'b11101, // 29
  EP2_DNO = 'b11100, // 28
  EP2_UO = 'b11011, // 27
  EP2_SHRR = 'b11010, // 26
  EP2_MRPI = 'b11001, // 25
  EP2_MRPD = 'b11000, // 24

  EP2_CC = 'b10111, // 23
  EP2_COV = 'b10110, // 22
  EP2_SHRR = 'b10101, // 21
  EP2_HALT = 'b10100, // 20
  EP2_UNCLAIMED_19 = 'b10011, // 19
  EP2_UNCLAIMED_18 = 'b10010, // 18
  EP2_UNCLAIMED_17 = 'b10001, // 17
  EP2_UNCLAIMED_16 = 'b10000, // 16

  EP2_UNCLAIMED_15 = 'b01111, // 15
  EP2_UNCLAIMED_14 = 'b01110, // 14
  EP2_UNCLAIMED_13 = 'b01101, // 13
  EP2_UNCLAIMED_12 = 'b01100, // 12
  EP2_UNCLAIMED_11 = 'b01011, // 11
  EP2_UNCLAIMED_10 = 'b01010, // 10
  EP2_UNCLAIMED_9 = 'b01001, // 9
  EP2_UNCLAIMED_8 = 'b01000, // 8

  EP2_UNCLAIMED_7 = 'b00111, // 7
  EP2_UNCLAIMED_6 = 'b00110, // 6
  EP2_UNCLAIMED_5 = 'b00101, // 5
  EP2_UNCLAIMED_4 = 'b00100, // 4
  EP2_UNCLAIMED_3 = 'b00011, // 3
  EP2_UNCLAIMED_2 = 'b00010, // 2
  EP2_UNCLAIMED_1 = 'b00001, // 1
  EP2_UNCLAIMED_0 = 'b00000 // 0

} EP2 ;


module CPDecoder (
    lane,
    prefix_in_data,
    prefix_out_data,
    malformed,
    canon_out
);
    input Lane lane;
    input LongPrefix prefix_in_data;
    output LongPrefix prefix_out_data;
    output bit malformed;
    output CanonInsn canon_out;


    wire bit [5:0] leading = lane[5:0];
    wire bit [5:0] rix1 = lane[10:6];
    wire bit [5:0] rix2 = lane[15:11];
    wire bit [5:0] ep_1 = lane[15:11];
    wire bit [5:0] ep_2 = lane[10:6];
    wire bit [9:0] xi_imm = lane[15:5];
    wire bit [5:0] imm = lane[15:11];
    wire bit [5:0] test_code = lane[15:11];

    wire bit its_xi = leading == LB_XI;
    wire bit its_locking_load = 
        (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_UO);
    wire bit its_store_seq = 
        (leading == LB_EP1) && (ep_1 == EP1_SS);
    wire bit its_store_seq_rel = 
        (leading == LB_EP1) && (ep_1 == EP1_SR);
    wire bit its_export = 
        (leading == LB_EP1) && (ep_1 == EP1_SSS);
    wire bit its_iw = 
        (leading == LB_EP1) && (ep_1 == EP1_IW);
    wire bit its_cp = 
        (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_CSP);
    wire bit its_shrr = 
        (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_SHRR);
    wire bit its_flag = 
        (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_FLAG);
    wire bit is_link = 
        (leading == LB_EP1) && (ep_1 == EP1_LINK);
    wire bit is_mrpd = 
        (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_MRPD);
    wire bit is_mrpi = 
        (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_MRPI);
    wire bit is_mulw = 
        (leading == LB_EP1) && (ep_1 == EP1_MULW);
    wire bit is_xcp = (leading == LB_XCP) ;
    wire bit is_xcn = (leading == LB_XCN) ;
    wire bit is_xc = is_xcp || is_xcn;

    LongPrefix prefix;

    wire bit any_store_prefix = 
        its_store_seq || its_store_seq_rel || its_export || its_iw ;
    wire bit any_store_prefix_in_prefix = 
        prefix.its_store_seq || prefix.its_store_seq_rel || 
        prefix.its_export || prefix.its_iw ;

    function automatic void merge_prefixes();
        prefix = '{default:0};
        if (prefix_in_data.recognised) begin
            prefix = prefix_in_data;
        end
        if (its_xi) begin
            if (prefix.is_xi) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_xi = 1;
            prefix.xi_bits = xi_imm;
            prefix_out_valid = 1;
            return;
        end
        if (its_locking_load) begin
            if (prefix.is_locking_load) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_locking_load = 1;
            prefix_out_valid = 1;
            return;
        end
        if (any_store_prefix) begin
            if (any_store_prefix_in_prefix) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.store_aug = store_aug;
            prefix.is_iw = its_iw;
            prefix.is_store_seq = its_store_seq;
            prefix.is_store_seq_rel = its_store_seq_rel;
            prefix.is_export = its_export;
            prefix.store_counter_index = rix1;
            prefix_out_valid = 1;
            return;
        end
        if (its_cp) begin
            if (prefix.its_cp) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.its_cp = 1;
            prefix_out_valid = 1;
            return;
        end
        if (its_shrr) begin
            if (prefix.is_shrr) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_shrr = 1;
            prefix_out_valid = 1;
            return;
        end
        if (its_flag) begin
            if (prefix.is_flag) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_flag = 1;
            prefix_out_valid = 1;
            return;
        end
        if (is_xc) begin
            if (prefix.is_xc) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_xc = 1;
            prefix.is_n = is_xcn;
            prefix.xc_flag_rix = rix1;
            prefix.test_code = test_code;
            prefix_out_valid = 1;
            return;
        end
        if (is_link) begin
            if (prefix.is_link) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_link = 1;
            prefix.link_dst = rix1;
            prefix_out_valid = 1;
            return;
        end
        if (is_mrpd) begin
            if (prefix.is_mrpd) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_mrpd = 1;
            prefix_out_valid = 1;
            return;
        end
        if (is_mrpi) begin
            if (prefix.is_mrpi) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_mrpi = 1;
            prefix_out_valid = 1;
            return;
        end
        if (is_mulw) begin
            if (prefix.is_mulw) begin
                prefix.malformed = 1;
                return;
            end
            prefix.recognised = 1;
            prefix.is_mulw = 1;
            prefix_out_valid = 1;
        end
    endfunction

    wire bit is_add = leading == LB_ADD;
    wire bit is_sub = leading == LB_SUB;
    wire bit is_mul = leading == LB_MUL;
    wire bit is_div = leading == LB_DIV;
    wire bit is_and = leading == LB_AND;
    wire bit is_or = leading == LB_OR;
    wire bit is_tst = leading == LB_TST;
    wire bit is_tstn = leading == LB_TSTN;
    wire bit is_xor = leading == LB_XOR;
    wire bit is_shra = leading == LB_SHRA;
    wire bit is_shr = leading == LB_SHR;
    wire bit is_shl = leading == LB_SHL;
    wire bit is_ld_8 = leading == LB_LD8;
    wire bit is_ld_16 = leading == LB_LD16;
    wire bit is_ld_32 = leading == LB_LD32;
    wire bit is_ld_f32 = leading == LB_LDF32;
    wire bit is_disp = leading == LB_DISP;
    wire bit is_dispi = leading == LB_DISPI;
    wire bit is_st = leading == LB_ST;
    wire bit is_cpy = leading == LB_CPY;
    wire bit is_puc = leading == LB_PUC;
    wire bit is_not = (leading == LB_EP1) && (ep_1 == NOT);
    wire bit is_neg = (leading == LB_EP1) && (ep_1 == NEG);
    wire bit is_gt = (leading == LB_GT);
    wire bit is_gte = (leading == LB_GTE);
    wire bit is_lt = (leading == LB_LT);
    wire bit is_lte = (leading == LB_LTE);

    wire bit [16:0] bundle = {
        prefix.is_xi , // 0 
        0 , // 1 
        prefix.is_locking_load , // 2

        prefix.is_store_seq , // 3
        prefix.is_store_seq_rel , // 4
        prefix.is_export , // 5
        prefix.is_iw , // 6

        prefix.is_cp , // 7
        prefix.is_shrr , // 8
        prefix.is_flag , // 9
        prefix.is_xc, // 10
        prefix.is_link, // 11
        0, // 12
        0, // 13
        prefix.is_mrpd, // 14
        prefix.is_mrpi, // 15
        prefix.is_mulw // 16
    };
    localparam BUNDLE_XI = 1 << 0;
    localparam BUNDLE_XT = 1 << 1;
    localparam BUNDLE_LL = 1 << 2;
    localparam BUNDLE_SS = 1 << 3;
    localparam BUNDLE_SSR = 1 << 4;
    localparam BUNDLE_EXPORT = 1 << 5;
    localparam BUNDLE_IW = 1 << 6;
    localparam BUNDLE_CP = 1 << 7;
    localparam BUNDLE_SHRR = 1 << 8;
    localparam BUNDLE_FLAG = 1 << 9;
    localparam BUNDLE_XC = 1 << 10;
    localparam BUNDLE_LINK = 1 << 11;
    localparam BUNDLE_OV = 1 << 12;
    localparam BUNDLE_CC = 1 << 13;
    localparam BUNDLE_MRPD = 1 << 14;
    localparam BUNDLE_MRPI = 1 << 15;
    localparam BUNDLE_MULW = 1 << 16;

    // load constants
    wire bit lc_s5 = 
        !prefix_in_valid && is_puc;
    wire bit lc_s15 = 
        prefix_in_valid && (bundle ^ (BUNDLE_XI)) == 0;
        
    // load from mem
    wire bit ld_b8 = 
        !prefix_in_valid && is_ld_8 ;
    wire bit ld_b16 = 
        !prefix_in_valid && is_ld_16 ;
    wire bit ld_b32 = 
        !prefix_in_valid && is_ld_32 ;
    wire bit ld_f32 = 
        !prefix_in_valid && is_ld_f32 ;

    // load from mem + offset
    wire bit ld_b8_off = 
        prefix_in_valid && is_ld_8 && (bundle ^ (BUNDLE_XI)) == 0;
    wire bit ld_b16_off = 
        prefix_in_valid && is_ld_16 && (bundle ^ (BUNDLE_XI)) == 0;
    wire bit ld_b32_off = 
        prefix_in_valid && is_ld_32 && (bundle ^ (BUNDLE_XI)) == 0;
    wire bit ld_f32_off = 
        prefix_in_valid && is_ld_f32 && (bundle ^ (BUNDLE_XI)) == 0;

    // locking load from mem
    wire bit ld_lock_b8 = 
        prefix_in_valid && is_ld_8 && (bundle ^ (BUNDLE_LL)) == 0;
    wire bit ld_lock_b16 = 
        prefix_in_valid && is_ld_16 && (bundle ^ (BUNDLE_LL)) == 0;
    wire bit ld_lock_b32 = 
        prefix_in_valid && is_ld_32 && (bundle ^ (BUNDLE_LL)) == 0;
    
    // reg2reg copy
    wire bit cpy = 
        !prefix_in_valid && is_cpy;

    // store to memory
    wire bit st = 
        !prefix_in_valid && is_st;

    // sequenced store
    wire bit st_seq = 
        prefix_in_valid && is_st && (bundle ^ (BUNDLE_SS)) == 0;
    // relese store for sequenced store
    wire bit st_seq_rel = 
        prefix_in_valid && is_st && (bundle ^ (BUNDLE_SSR)) == 0;
    // propogate local changes to other executors
    wire bit export_span = 
        prefix_in_valid && is_st && (bundle ^ (BUNDLE_EXPORT)) == 0;
    // store instruction with icache invalidation
    wire bit st_insn = 
        prefix_in_valid && is_st && (bundle ^ (BUNDLE_IW)) == 0;
    
    // load from status register
    wire bit ld_msr_8 = 
        prefix_in_valid && is_ld_8 && (bundle ^ (BUNDLE_CP)) == 0;
    wire bit ld_msr_16 = 
        prefix_in_valid && is_ld_16 && (bundle ^ (BUNDLE_CP)) == 0;
    wire bit ld_msr_32 = 
        prefix_in_valid && is_ld_32 && (bundle ^ (BUNDLE_CP)) == 0;
    
    // store to control register
    wire bit st_mcr = 
        prefix_in_valid && is_st && (bundle ^ (BUNDLE_CP)) == 0;
    
    // add reg reg vals
    wire bit add_rr = 
        !prefix_in_valid && is_add;
    // sub reg reg
    wire bit sub_rr = !prefix_in_valid && is_sub;
    // mul reg reg
    wire bit mul_rr = !prefix_in_valid && is_mul;
    // div reg regd
    wire bit div_rr = !prefix_in_valid && is_div;
    // bitwise and reg regd
    wire bit and_rr = !prefix_in_valid && is_and;
    // bitwise or reg regd
    wire bit or_rr  = !prefix_in_valid && is_or;
    // bitwise xor reg regd
    wire bit xor_rr = !prefix_in_valid && is_xor;
    // wide mul reg by reg
    wire bit mulw_rr = 
        prefix_in_valid && is_mul && (bundle ^ BUNDLE_MULW) == 0;
    // wide mul reg by imm
    wire bit mulw_ri = 
        prefix_in_valid && is_mul && (bundle ^ (BUNDLE_XI | BUNDLE_MULW)) == 0;

    wire bit add_ri = prefix_in_valid && is_add && (bundle ^ BUNDLE_XI) == 0;
    wire bit mul_ri = prefix_in_valid && is_mul && (bundle ^ BUNDLE_XI) == 0;
    wire bit sub_ri = prefix_in_valid && is_sub && (bundle ^ BUNDLE_XI) == 0;
    wire bit div_ri = prefix_in_valid && is_div && (bundle ^ BUNDLE_XI) == 0;
    wire bit and_ri = prefix_in_valid && is_and && (bundle ^ BUNDLE_XI) == 0;
    wire bit or_ri  = prefix_in_valid && is_or  && (bundle ^ BUNDLE_XI) == 0;
    wire bit xor_ri = prefix_in_valid && is_xor && (bundle ^ BUNDLE_XI) == 0;

    // bitwise invertion
    wire bit inv = !prefix_in_valid && is_not;
    // 2comp invertion aka diadic additive inversion
    wire bit neg = !prefix_in_valid && is_neg;

    // logical shift left reg by reg
    wire bit shl_rr = 
        prefix_in_valid && is_shl && (bundle ^ BUNDLE_SHRR) == 0;
    // logical shift right reg by reg
    wire bit shr_rr = 
        prefix_in_valid && is_shr && (bundle ^ BUNDLE_SHRR) == 0;
    // arith shift right reg by reg
    wire bit shra_rr = 
        prefix_in_valid && is_shra && (bundle ^ BUNDLE_SHRR) == 0;

    // logical shift left reg by imm
    wire bit shl_ri = !prefix_in_valid && is_shl ;
    // logical shift right reg by imm
    wire bit shr_ri = !prefix_in_valid && is_shr ;
    // arith shift right reg by imm
    wire bit shra_ri = !prefix_in_valid && is_shra ;

    // 
    wire bit disp_imm          = 
        !prefix_in_valid && is_dispi;
    wire bit disp_imm_xim      =
         prefix_in_valid && is_dispi && (bundle ^ BUNDLE_XI) == 0;
    wire bit disp_imm_xim_link =
         prefix_in_valid && is_dispi && (bundle ^ (BUNDLE_XI | BUNDLE_LINK)) == 0;

    wire bit disp_reg_off       = 
        !prefix_in_valid && is_disp && (ep_1 == DISP_OFF);
    wire bit disp_reg_off_link  = 
        prefix_in_valid  && is_disp && (ep_1 == DISP_OFF) && ((bundle ^ BUNDLE_LINK) == 0);
    wire bit disp_reg_addr      = 
        !prefix_in_valid && is_disp && (ep_1 == DISP_ABS);
    wire bit disp_reg_addr_link = 
        prefix_in_valid  && is_disp && (ep_1 == DISP_ABS) && ((bundle ^ BUNDLE_LINK) == 0);

    wire bit disp_reg_addr_wic      = 
        prefix_in_valid && is_disp && (ep_1 == DISP_ABS) && ((bundle ^ BUNDLE_IW) == 0);
    wire bit disp_reg_addr_link_wic = 
        prefix_in_valid  && is_disp && (ep_1 == DISP_ABS) && (bundle ^ (BUNDLE_LINK | BUNDLE_IW)) == 0;

    wire bit ctrl_trn = 
        !prefix_in_valid && (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_TC);
    wire bit halt    = 
        !prefix_in_valid && (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_HALT);
    wire bit nop     = 
        !prefix_in_valid && (leading == LB_EP1) && (ep_1 == EP1_EP2) && (ep_2 == EP2_DNO);

    wire bit flag_and = 
        prefix_in_valid && is_and && (bundle ^ BUNDLE_FLAG) == 0;
    wire bit flag_or = 
        prefix_in_valid && is_or && (bundle ^ BUNDLE_FLAG) == 0;
    wire bit flag_not = 
        prefix_in_valid && is_not && (bundle ^ BUNDLE_FLAG) == 0;

    wire bit cmp_eq  = !prefix_in_valid && is_tst;
    wire bit cmp_neq = !prefix_in_valid && is_tstn;
    wire bit cmp_eq_ri = prefix_in_valid && is_tst && (bundle ^ BUNDLE_XI) == 0;
    wire bit cmp_neq_ri = prefix_in_valid && is_tstn && (bundle ^ BUNDLE_XI) == 0;

    wire bit cmp_gt_rr =  !prefix_in_valid && is_gt;
    wire bit cmp_gte_rr = !prefix_in_valid && is_gte ;
    wire bit cmp_lt_rr = !prefix_in_valid && is_lt ;
    wire bit cmp_lte_rr = !prefix_in_valid && is_lte;

    wire bit cmp_gt_ri =  prefix_in_valid && is_gt && (bundle ^ BUNDLE_XI) == 0;
    wire bit cmp_gte_ri = prefix_in_valid && is_gte && (bundle ^ BUNDLE_XI) == 0;
    wire bit cmp_lt_ri = prefix_in_valid && is_lt && (bundle ^ BUNDLE_XI) == 0;
    wire bit cmp_lte_ri = prefix_in_valid && is_lte && (bundle ^ BUNDLE_XI) == 0;

    wire bit pfd = 
        prefix_in_valid && is_tst && (bundle ^ BUNDLE_MRPD) == 0;
    wire bit pfi = 
        prefix_in_valid && is_tst && (bundle ^ BUNDLE_MRPI) == 0;

    CanonInsn canon_insn;

    function automatic void handle_base();
        canon_insn = '{default:0};
        if (prefix.is_xc) begin
            canon_insn.conditional = 1;
            canon_insn.test_code = prefix.test_code;
            canon_insn.test_reg = prefix.xc_flag_rix;
        end
        if (lc_s5) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_PutConst;
            canon_insn.payload.put_const = '{
                large: 0,
                imm: imm
            };
            return;
        end
        if (lc_s15) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_PutConst;
            canon_insn.payload.put_const = '{
                large: 1,
                imm: xi_imm
            };
            return;
        end
        if (ld_b8) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B8,
                try_locking: 0,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_b16) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B16,
                try_locking: 0,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_b32) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B32,
                try_locking: 0,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_f32) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_F32,
                try_locking: 0,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_b8_off) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B8,
                try_locking: 0,
                apply_offset: 1,
                offset: prefix.xi_bits
            };
            return;
        end
        if (ld_b16_off) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B16,
                try_locking: 0,
                apply_offset: 1,
                offset: prefix.xi_bits
            };
            return;
        end
        if (ld_b32_off) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B32,
                try_locking: 0,
                apply_offset: 1,
                offset: prefix.xi_bits
            };
            return;
        end
        if (ld_f32_off) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_F32,
                try_locking: 0,
                apply_offset: 1,
                offset: prefix.xi_bits
            };
            return;
        end
        if (ld_lock_b8) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B8,
                try_locking: 1,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_lock_b16) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B16,
                try_locking: 1,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_lock_b32) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_B32,
                try_locking: 1,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (ld_lock_f32) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemLoad;
            canon_insn.payload.mem_load_op = '{
                dst: rix1,
                addr_rix: rix2,
                datatype: RDT_F32,
                try_locking: 1,
                apply_offset: 0,
                offset: 0
            };
            return;
        end
        if (cpy) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Copy;
            canon_insn.payload.copy_op = '{
                src: rix1,
                dst: rix2
            };
            return;
        end
        if (st) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemStore;
            canon_insn.payload.mem_store_op = '{
                value_rix: rix2,
                addr_rix: rix1,
                store_aug: StoreAug_None,
                counter_ix: 0,
                apply_offset: 0,
                offset: 0,
                icache_inv: 0
            };
            return;
        end
        if (st_seq) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemStore;
            canon_insn.payload.mem_store_op = '{
                value_rix: rix2,
                addr_rix: rix1,
                store_aug: StoreAug_Sequenced,
                counter_ix: 0,
                apply_offset: 0,
                offset: 0,
                icache_inv: 0
            };
            return;
        end
        if (st_seq_rel) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemStore;
            canon_insn.payload.mem_store_op = '{
                value_rix: rix2,
                addr_rix: rix1,
                store_aug: StoreAug_Release,
                counter_ix: prefix.store_counter_index,
                apply_offset: 0,
                offset: 0,
                icache_inv: 0
            };
            return;
        end
        if (export_span) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ExportSpan;
            canon_insn.payload.export_span = '{
                start_rix: rix1,
                span_rix: rix2,
                wix: prefix.store_counter_index
            };
            return;
        end
        if (st_insn) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_MemStore;
            canon_insn.payload.mem_store_op = '{
                value_rix: rix2,
                addr_rix: rix1,
                store_aug: StoreAug_Release,
                counter_ix: prefix.store_counter_index,
                apply_offset: 0,
                offset: 0,
                icache_inv: 1
            };
            return;
        end
        if (ld_msr_8) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_PCtrl;
            canon_insn.payload.platform_control_op = '{
                op_variant: PCtrlV_Get,
                datatype: RDT_B8,
                op1: rix1,
                op2: rix2
            };
            return;
        end
        if (ld_msr_16) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_PCtrl;
            canon_insn.payload.platform_control_op = '{
                op_variant: PCtrlV_Get,
                datatype: RDT_B16,
                op1: rix1,
                op2: rix2
            };
            return;
        end
        if (ld_msr_32) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_PCtrl;
            canon_insn.payload.platform_control_op = '{
                op_variant: PCtrlV_Get,
                datatype: RDT_B32,
                op1: rix1,
                op2: rix2
            };
            return;
        end
        if (st_mcr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_PCtrl;
            canon_insn.payload.platform_control_op = '{
                op_variant: PCtrlV_Set,
                op1: rix1,
                op2: rix2
            };
            return;
        end
        if (add_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Add,
                rix1: rix1,
                rix2_imm1: rix2,
                imm_present: 0,
                rix3: 0,
                imm2: 0
            };
            return;
        end
        if (sub_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Sub,
                rix1: rix1,
                rix2_imm1: rix2,
                imm_present: 0,
                rix3: 0,
                imm2: 0
            };
            return;
        end
        if (mul_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Mul,
                rix1: rix1,
                rix2_imm1: rix2,
                imm_present: 0,
                rix3: 0,
                imm2: 0
            };
            return;
        end
        if (div_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Div,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (and_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_And,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (or_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Or,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (xor_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (mulw_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Add,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: prefix.upper_dst,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (add_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Add,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (sub_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Sub,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (mul_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Mul,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (div_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Div,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (and_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_And,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (or_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Or,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (xor_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Xor,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (mulw_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Add,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: prefix.upper_dst,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (neg) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Neg,
                rix1: rix1,
                rix2_imm1: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (inv) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Not,
                rix1: rix1,
                rix2_imm1: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (shl_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Shl,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (shr_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Shr,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (shra_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_ShrA,
                rix1: rix1,
                rix2_imm1: rix2,
                rix3: 0,
                imm_present: 0,
                imm2: 0
            };
            return;
        end
        if (shl_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Shl,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (shr_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_Shr,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (shra_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_ArithLogic;
            canon_insn.payload.arith_logic_op = '{
                arith_variant: ArithV_ShrA,
                rix1: rix1,
                rix2_imm1: imm,
                rix3: 0,
                imm_present: 1,
                imm2: imm2
            };
            return;
        end
        if (disp_imm) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Off_Imm,
                offset: xi_imm,
                has_extra: 0,
                extra_offset: 0,
                src: 0,
                must_wait: 0,
                wix: 0,
                link: 0,
                link_dst: 0
            };
            return;
        end
        if (disp_imm_xim) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Off_Imm,
                offset: xi_imm,
                has_extra: 1,
                extra_offset: prefix.xi_bits,
                src: 0,
                must_wait: 0,
                wix: 0,
                link: 0,
                link_dst: 0
            };
            return;
        end
        if (disp_imm_xim_link) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Off_Imm,
                offset: xi_imm,
                has_extra: 1,
                extra_offset: prefix.xi_bits,
                src: 0,
                must_wait: 0,
                wix: 0,
                link: 1,
                link_dst: prefix.link_dst
            };
            return;
        end
        if (disp_reg_off) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Off_Reg,
                offset: 0,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 0,
                wix: 0,
                link: 0,
                link_dst: 0
            };
            return;
        end
        if (disp_reg_off_link) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Off_Reg,
                offset: 0,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 0,
                wix: 0,
                link: 0,
                link_dst: 0
            };
            return;
        end
        if (disp_reg_off_link) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Off_Reg,
                offset: imm,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 0,
                wix: 0,
                link: 1,
                link_dst: prefix.link_dst
            };
            return;
        end
        if (disp_reg_addr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Addr_Reg,
                offset: imm,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 0,
                wix: 0,
                link: 0,
                link_dst: 0
            };
            return;
        end
        if (disp_reg_addr_link) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Addr_Reg,
                offset: imm,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 0,
                wix: 0,
                link: 1,
                link_dst: prefix.link_dst
            };
            return;
        end
        if (disp_reg_addr_wic) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Addr_Reg,
                offset: imm,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 1,
                wix: prefix.store_counter_index,
                link: 0,
                link_dst: 0
            };
            return;
        end
        if (disp_reg_addr_link_wic) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Disp;
            canon_insn.payload.disp_op = '{
                disp_variant: DispV_Addr_Reg,
                offset: imm,
                has_extra: 0,
                extra_offset: 0,
                src: rix1,
                must_wait: 1,
                wix: prefix.store_counter_index,
                link: 1,
                link_dst: prefix.link_dst
            };
            return;
        end
        if (flag_and) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_FlagOp;
            canon_insn.payload.flag_op = '{
                variant: FlagOpV_And,
                rix1: rix1,
                rix2: rix2
            };
            return;
        end
        if (flag_or) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_FlagOp;
            canon_insn.payload.flag_op = '{
                variant: FlagOpV_Or,
                rix1: rix1,
                rix2: rix2
            };
            return;
        end
        if (flag_not) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_FlagOp;
            canon_insn.payload.flag_op = '{
                variant: FlagOpV_Not,
                rix1: rix1,
                rix2: 0
            };
            return;
        end
        if (cmp_eq) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_Eq,
                rix1: rix1,
                rix2_imm: rix2,
                imm2: 0,
                is_imm: 0
            };
            return;
        end
        if (cmp_neq) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_NEq,
                rix1: rix1,
                rix2_imm: rix2,
                imm2: 0,
                is_imm: 0
            };
            return;
        end
        if (cmp_eq_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_Eq,
                rix1: rix1,
                rix2_imm: imm,
                imm2: prefix.xi_bits,
                is_imm: 1
            };
            return;
        end
        if (cmp_neq_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_NEq,
                rix1: rix1,
                rix2_imm: imm,
                imm2: prefix.xi_bits,
                is_imm: 1
            };
            return;
        end
        if (cmp_gt_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_GT,
                rix1: rix1,
                rix2_imm: rix2,
                imm2: 0,
                is_imm: 0
            };
            return;
        end
        if (cmp_gte_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_GTE,
                rix1: rix1,
                rix2_imm: rix2,
                imm2: 0,
                is_imm: 0
            };
            return;
        end
        if (cmp_lt_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_LT,
                rix1: rix1,
                rix2_imm: rix2,
                imm2: 0,
                is_imm: 0
            };
            return;
        end
        if (cmp_lte_rr) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_LTE,
                rix1: rix1,
                rix2_imm: rix2,
                imm2: 0,
                is_imm: 0
            };
            return;
        end
        if (cmp_gt_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_GT,
                rix1: rix1,
                rix2_imm: imm,
                imm2: prefix.xi_bits,
                is_imm: 1
            };
            return;
        end
        if (cmp_gte_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_GTE,
                rix1: rix1,
                rix2_imm: imm,
                imm2: prefix.xi_bits,
                is_imm: 1
            };
            return;
        end
        if (cmp_lt_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_LT,
                rix1: rix1,
                rix2_imm: imm,
                imm2: prefix.xi_bits,
                is_imm: 1
            };
            return;
        end
        if (cmp_lte_ri) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_CmpOp;
            canon_insn.payload.cmp_op = '{
                variant: CmpOpV_LTE,
                rix1: rix1,
                rix2_imm: imm,
                imm2: prefix.xi_bits,
                is_imm: 1
            };
            return;
        end
        if (pfd) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Fetch;
            canon_insn.payload.fetch_op = '{
                addr_rix: rix1,
                span_rix: rix2,
                insn: 0
            };
            return;
        end
        if (pfi) begin
            canon_insn.valid = 1;
            canon_insn.insn_variant = CanonInsnV_Fetch;
            canon_insn.payload.fetch_op = '{
                addr_rix: rix1,
                span_rix: rix2,
                insn: 1
            };
            return;
        end
    endfunction
    function automatic void perform_decode();
        merge_prefixes();
        handle_base();
    endfunction

    bit insn_valid;
    always_comb begin
        perform_decode();
        prefix_out_data = prefix;
        insn_valid = (canon_insn.valid && !prefix.malformed);
        malformed = !insn_valid;
        canon_out = canon_insn;
    end

endmodule

typedef struct {
    bit malformed;
    bit recognised;

    bit is_xi;
    bit [9:0] xi_bits;

    bit is_locking_load;

    bit is_store_seq;
    bit is_store_seq_rel;
    bit is_export;
    bit is_iw;
    bit [4:0] store_counter_index;

    bit is_link;
    bit [4:0] link_dst;

    bit is_csp;

    bit is_shrr;

    bit is_flag;

    bit is_xc;
    bit is_n;
    bit xc_flag_rix;
    bit [4:0] test_code;

    bit is_ov_chk;
    bit is_cr_chk;

    bit is_mrpd;
    bit is_mrpi;

    bit is_mulw;
    bit [4:0] upper_dst;

} LongPrefix;

typedef enum bit [3:0] {

  CanonInsnV_ArithLogic = 'b1111, // 15
  CanonInsnV_MemLoad = 'b1110, // 14
  CanonInsnV_MemStore = 'b1101, // 13
  CanonInsnV_Disp = 'b1100, // 12
  CanonInsnV_Fetch = 'b1011, // 11
  CanonInsnV_Copy = 'b1010, // 10
  CanonInsnV_ExportSpan = 'b1001, // 9
  CanonInsnV_PCtrl = 'b1000, // 8

  CanonInsnV_FlagOp = 'b0111, // 7
  CanonInsnV_CmpOp = 'b0110, // 6
  CanonInsnV_UNCLAIMED_5 = 'b0101, // 5
  CanonInsnV_UNCLAIMED_4 = 'b0100, // 4
  CanonInsnV_UNCLAIMED_3 = 'b0011, // 3
  CanonInsnV_UNCLAIMED_2 = 'b0010, // 2
  CanonInsnV_UNCLAIMED_1 = 'b0001, // 1
  CanonInsnV_UNCLAIMED_0 = 'b0000 // 0

} CanonInsnV ;

typedef struct {
    bit valid;
    bit [31:0] addr;
    bit conditional;
    TestV test_code;
    bit [4:0] test_reg;
    CanonInsnV insn_variant;
    CanonInsnPayload payload;
} CanonInsn ;

typedef union {
    MemLoadOp mem_load_op;
    MemStoreOp mem_store_op;
    DispOp disp_op;
    FetchOp fetch_op;
    ALOp arith_logic_op;
    PutConstant put_const;
    CopyOp copy_op;
    ExportSpan export_span;
    PCtrlOp platform_control_op;
    FlagOp flag_op;
    CmpOp cmp_op;
} CanonInsnPayload ;

typedef enum bit [1:0] {

  RDT_B8 = 'b11, // 3
  RDT_B16 = 'b10, // 2
  RDT_B32 = 'b01, // 1
  RDT_F32 = 'b00 // 0

} RDT ;

typedef struct {
    bit [4:0] dst;
    bit [4:0] addr_rix;
    RDT datatype;
    bit try_locking;
    bit apply_offset;
    bit [9:0] offset;
} MemLoadOp ;

typedef enum bit [2:0] {

  StoreAug_None = 'b111, // 7
  StoreAug_Sequenced = 'b110, // 6
  StoreAug_SpanExport = 'b101, // 5
  StoreAug_InsnStore = 'b100, // 4
  StoreAug_Release = 'b011, // 3
  StoreAug_UNCLAIMED_2 = 'b010, // 2
  StoreAug_UNCLAIMED_1 = 'b001, // 1
  StoreAug_UNCLAIMED_0 = 'b000 // 0

} StoreAug ;

typedef struct {
    bit [4:0] value_rix;
    bit [4:0] addr_rix;
    StoreAug store_aug;
    bit [4:0] counter_ix;
    bit apply_offset;
    bit [9:0] offset;
    bit icache_inv;
} MemStoreOp ;

typedef enum bit [3:0] {

  ArithV_Add = 'b1111, // 15
  ArithV_Sub = 'b1110, // 14
  ArithV_Mul = 'b1101, // 13
  ArithV_Div = 'b1100, // 12
  ArithV_Shl = 'b1011, // 11
  ArithV_Shr = 'b1010, // 10
  ArithV_ShrA = 'b1001, // 9
  ArithV_And = 'b1000, // 8

  ArithV_Or = 'b0111, // 7
  ArithV_Not = 'b0110, // 6
  ArithV_Neg = 'b0101, // 5
  ArithV_Xor = 'b0100, // 4
  ArithV_UNCLAIMED_3 = 'b0011, // 3
  ArithV_UNCLAIMED_2 = 'b0010, // 2
  ArithV_UNCLAIMED_1 = 'b0001, // 1
  ArithV_UNCLAIMED_0 = 'b0000 // 0

} ArithV ;

typedef struct {
    ArithV arith_variant;
    bit [4:0] rix1;
    bit [4:0] rix2_imm1;
    bit imm_present;
    bit [9:0] imm2;
    bit [4:0] rix3;
} ALOp ;

typedef enum bit [1:0] {

  DispV_Off_Imm = 'b11, // 3
  DispV_Off_Reg = 'b10, // 2
  DispV_Addr_Reg = 'b01, // 1
  DispV_UNCLAIMED_0 = 'b00 // 0

} DispV ;

typedef struct {
    DispV disp_variant;
    bit [9:0] offset;
    bit has_extra;
    bit [9:0] extra_offset;
    bit [4:0] src;
    bit must_wait;
    bit [4:0] wix;
    bit link;
    bit [4:0] link_dst;
} DispOp ;

typedef struct {
    bit [4:0] addr_rix;
    bit [4:0] span_rix;
    bit insn;
} FetchOp ;

typedef struct {
    bit large;
    union {
        bit [9:0] small;
        bit [4:0] large;
    } imm ;
} PutConstant;

typedef struct {
    bit [4:0] src;
    bit [4:0] dst;
} CopyOp ;

typedef struct {
    bit [4:0] start_rix ;
    bit [4:0] span_rix ;
    bit [4:0] wix ;
} ExportSpan ;

typedef enum bit [0:0] {

  PCtrlV_Get = 'b1, // 1
  PCtrlV_Set = 'b0 // 0

} PCtrlV ;

typedef struct {
    PCtrlV op_variant;
    bit [4:0] op1;
    bit [4:0] op2;
    RDT datatype;
} PCtrlOp;

typedef enum bit [1:0] {

  FlagOpV_And = 'b11, // 3
  FlagOpV_Or = 'b10, // 2
  FlagOpV_Not = 'b01, // 1
  FlagOpV_UNCLAIMED_0 = 'b00 // 0

} FlagOpV ;

typedef struct {
    FlagOpV variant;
    bit [4:0] rix1;
    bit [4:0] rix2;
} FlagOp ;

typedef enum bit [2:0] {

  CmpOpV_LT = 'b111, // 7
  CmpOpV_LTE = 'b110, // 6
  CmpOpV_GT = 'b101, // 5
  CmpOpV_GTE = 'b100, // 4
  CmpOpV_Eq = 'b011, // 3
  CmpOpV_NEq = 'b010, // 2
  CmpOpV_UNCLAIMED_1 = 'b001, // 1
  CmpOpV_UNCLAIMED_0 = 'b000 // 0

} CmpOpV ;

typedef struct {
    CmpOpV variant;
    bit [4:0] rix1;
    bit [4:0] rix2_imm;
    bit [9:0] imm2;
    bit is_imm;
} CmpOp ;

typedef enum bit [4:0] {

  TestV_FlagSet = 'b11111, // 31
  TestV_RegOverflow = 'b11110, // 30
  TestV_RegCarry = 'b11101, // 29
  TestV_RegZero = 'b11100, // 28
  TestV_RegOne = 'b11011, // 27
  TestV_RegMinusOne = 'b11010, // 26
  TestV_UNCLAIMED_25 = 'b11001, // 25
  TestV_UNCLAIMED_24 = 'b11000, // 24

  TestV_UNCLAIMED_23 = 'b10111, // 23
  TestV_UNCLAIMED_22 = 'b10110, // 22
  TestV_UNCLAIMED_21 = 'b10101, // 21
  TestV_UNCLAIMED_20 = 'b10100, // 20
  TestV_UNCLAIMED_19 = 'b10011, // 19
  TestV_UNCLAIMED_18 = 'b10010, // 18
  TestV_UNCLAIMED_17 = 'b10001, // 17
  TestV_UNCLAIMED_16 = 'b10000, // 16

  TestV_UNCLAIMED_15 = 'b01111, // 15
  TestV_UNCLAIMED_14 = 'b01110, // 14
  TestV_UNCLAIMED_13 = 'b01101, // 13
  TestV_UNCLAIMED_12 = 'b01100, // 12
  TestV_UNCLAIMED_11 = 'b01011, // 11
  TestV_UNCLAIMED_10 = 'b01010, // 10
  TestV_UNCLAIMED_9 = 'b01001, // 9
  TestV_UNCLAIMED_8 = 'b01000, // 8

  TestV_UNCLAIMED_7 = 'b00111, // 7
  TestV_UNCLAIMED_6 = 'b00110, // 6
  TestV_UNCLAIMED_5 = 'b00101, // 5
  TestV_UNCLAIMED_4 = 'b00100, // 4
  TestV_UNCLAIMED_3 = 'b00011, // 3
  TestV_UNCLAIMED_2 = 'b00010, // 2
  TestV_UNCLAIMED_1 = 'b00001, // 1
  TestV_UNCLAIMED_0 = 'b00000 // 0

} TestV ;



module StripeDecoder (
    clk,
    ifas_in,
    dec_out
);
    input bit clk;
    PipeRecievePort ifas_in;
    PipeSendPort dec_out;

    wire bit [7:0][15:0] codepoints = ifas_in.last.stripe;

    LongPrefix prefix_outs [7:0];
    LongPrefix prefix_ins [7:0];
    bit malformeds [7:0];
    CanonInsn [7:0] canon_outs ;

    for (genvar i = 0; i < 8; i++) begin
        CPDecoder ldec (
            .lane(codepoints[i]),
            .prefix_in_data(prefix_ins[i]),
            .prefix_out_data(prefix_outs[i]),
            .malformed(malformeds[i]),
            .masked_off(masked_offs[i]),
            .canon_out(canon_outs[i])
        );
    end
    for (genvar i = 0; i < 7; i++) begin
        assign prefix_ins[i+1] = prefix_outs[i];
    end

    wire LongPrefix tail = prefix_outs[7];
    wire bit tail_valid = valid_outs[7];
    wire LongPrefix head = prefix_ins[0];

    wire bit can_propagate = ifas_in.valid && !dec_out.full;

    LongPrefix tmp;
    always_ff @(posedge clk) begin
        tmp <= tail;
    end
    always_comb begin
        head = tmp;
        dec_out.data_in = '{
            blob_addr: ifas_in.last.blob_addr,
            insns: canon_outs
        };
        padb_out.drop = 0;
        dec_out.put = 0;
        if (can_propagate) begin
            padb_out.drop = 1;
            dec_out.put = 1;
        end
    end

endmodule


typedef struct {
    bit [31:0] blob_addr;
    bit [(16*8)-1:0] stripe;
} Blob;
typedef struct {
    bit [31:0] blob_addr;
    CanonInsn [7:0] insns;
} InsnPack;