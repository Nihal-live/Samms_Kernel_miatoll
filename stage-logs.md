# KernelSU_Action_V2 stage logs for run 45099495318

commit 9c2bfa5e31e2cfbb5412af7217ec8a5cf546a499, action 26c1b95532549d4cb57ab152f5650003d89c6efb

## build.log

```
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cp_stats/core/src/wlan_cp_stats_ol_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/os_if/linux/cp_stats/src/wlan_cfg80211_mc_cp_stats.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cp_stats/dispatcher/src/wlan_cp_stats_utils_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cp_stats/dispatcher/src/wlan_cp_stats_mc_tgt_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cp_stats/dispatcher/src/wlan_cp_stats_mc_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/target_if/interop_issues_ap/src/target_if_interop_issues_ap.o
  CC      drivers/staging/qcacld-3.0/components/interop_issues_ap/core/src/wlan_interop_issues_ap_api.o
  CC      drivers/staging/qcacld-3.0/os_if/interop_issues_ap/src/wlan_cfg80211_interop_issues_ap.o
  CC      drivers/staging/qcacld-3.0/components/interop_issues_ap/dispatcher/src/wlan_interop_issues_ap_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/interop_issues_ap/dispatcher/src/wlan_interop_issues_ap_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/nan/core/src/nan_main.o
  CC      drivers/staging/qcacld-3.0/components/nan/core/src/nan_api.o
  CC      drivers/staging/qcacld-3.0/components/nan/dispatcher/src/nan_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/nan/dispatcher/src/cfg_nan.o
  CC      drivers/staging/qcacld-3.0/components/target_if/nan/src/target_if_nan.o
  CC      drivers/staging/qcacld-3.0/os_if/nan/src/os_if_nan.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/mgmt_txrx/core/src/wlan_mgmt_txrx_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/mgmt_txrx/dispatcher/src/wlan_mgmt_txrx_utils_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/mgmt_txrx/dispatcher/src/wlan_mgmt_txrx_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/tdls/core/src/wlan_tdls_main.o
  CC      drivers/staging/qcacld-3.0/components/tdls/core/src/wlan_tdls_cmds_process.o
  CC      drivers/staging/qcacld-3.0/components/tdls/core/src/wlan_tdls_peer.o
  CC      drivers/staging/qcacld-3.0/components/tdls/core/src/wlan_tdls_mgmt.o
  CC      drivers/staging/qcacld-3.0/components/tdls/core/src/wlan_tdls_ct.o
  CC      drivers/staging/qcacld-3.0/components/tdls/dispatcher/src/wlan_tdls_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/tdls/dispatcher/src/wlan_tdls_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/tdls/dispatcher/src/wlan_tdls_utils_api.o
  CC      drivers/staging/qcacld-3.0/components/tdls/dispatcher/src/wlan_tdls_cfg.o
  CC      drivers/staging/qcacld-3.0/os_if/tdls/src/wlan_cfg80211_tdls.o
  CC      drivers/staging/qcacld-3.0/components/target_if/tdls/src/target_if_tdls.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_main.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_apf.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_arp.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_gtk.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_mc_addr_filtering.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_static_config.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_wow.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_lphb.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_suspend_resume.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_hw_filter.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_obj_mgmt_api.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_arp.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_gtk.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_wow.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_static_config.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_mc_addr_filtering.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_lphb.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_suspend_resume.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_hw_filter.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_pkt_filter.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_pkt_filter.o
  CC      drivers/staging/qcacld-3.0/components/pmo/core/src/wlan_pmo_ns.o
  CC      drivers/staging/qcacld-3.0/components/pmo/dispatcher/src/wlan_pmo_tgt_ns.o
  CC      drivers/staging/qcacld-3.0/components/p2p/dispatcher/src/wlan_p2p_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/p2p/dispatcher/src/wlan_p2p_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/p2p/dispatcher/src/wlan_p2p_cfg.o
  CC      drivers/staging/qcacld-3.0/components/p2p/dispatcher/src/wlan_p2p_api.o
  CC      drivers/staging/qcacld-3.0/components/p2p/core/src/wlan_p2p_main.o
  CC      drivers/staging/qcacld-3.0/components/p2p/core/src/wlan_p2p_roc.o
  CC      drivers/staging/qcacld-3.0/components/p2p/core/src/wlan_p2p_off_chan_tx.o
  CC      drivers/staging/qcacld-3.0/os_if/p2p/src/wlan_cfg80211_p2p.o
  CC      drivers/staging/qcacld-3.0/components/target_if/p2p/src/target_if_p2p.o
  CC      drivers/staging/qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_action.o
  CC      drivers/staging/qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_core.o
  CC      drivers/staging/qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_get_set_utils.o
  CC      drivers/staging/qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_init_deinit.o
  CC      drivers/staging/qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_ucfg.o
  CC      drivers/staging/qcacld-3.0/components/cmn_services/policy_mgr/src/wlan_policy_mgr_pcl.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/utils/nlink/src/wlan_nlink_srv.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/utils/ptt/src/wlan_ptt_sock_svc.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_utils.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_legacy_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_rules.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_internal.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_non_scan.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_queue.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/serialization/src/wlan_serialization_scan.o
  CC      drivers/staging/qcacld-3.0/core/pld/src/pld_common.o
  CC      drivers/staging/qcacld-3.0/core/pld/src/pld_snoc.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/sm_engine/src/wlan_sm_engine.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/mlme_objmgr/dispatcher/src/wlan_vdev_mlme_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/core/src/vdev_mlme_sm.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/dispatcher/src/wlan_vdev_mlme_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/core/src/vdev_mgr_ops.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/dispatcher/src/wlan_vdev_mgr_tgt_if_rx_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/dispatcher/src/wlan_vdev_mgr_tgt_if_tx_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/dispatcher/src/wlan_vdev_mgr_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/vdev_mgr/dispatcher/src/wlan_vdev_mgr_utils_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/mlme_objmgr/dispatcher/src/wlan_cmn_mlme_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/mlme_objmgr/dispatcher/src/wlan_pdev_mlme_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/pdev_mgr/dispatcher/src/wlan_pdev_mlme_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/mlme_objmgr/dispatcher/src/wlan_psoc_mlme_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/mlme/psoc_mgr/dispatcher/src/wlan_psoc_mlme_api.o
  CC      drivers/staging/qcacld-3.0/components/mlme/core/src/wlan_mlme_main.o
  CC      drivers/staging/qcacld-3.0/components/mlme/dispatcher/src/wlan_mlme_api.o
  CC      drivers/staging/qcacld-3.0/components/mlme/dispatcher/src/wlan_mlme_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/mlme/core/src/wlan_mlme_vdev_mgr_interface.o
  CC      drivers/staging/qcacld-3.0/components/fw_offload/core/src/wlan_fw_offload_main.o
  CC      drivers/staging/qcacld-3.0/components/fw_offload/dispatcher/src/wlan_fwol_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/fw_offload/dispatcher/src/wlan_fwol_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/target_if/fw_offload/src/target_if_fwol.o
  CC      drivers/staging/qcacld-3.0/os_if/fw_offload/src/os_if_fwol.o
  CC      drivers/staging/qcacld-3.0/components/blacklist_mgr/core/src/wlan_blm_main.o
  CC      drivers/staging/qcacld-3.0/components/blacklist_mgr/core/src/wlan_blm_core.o
  CC      drivers/staging/qcacld-3.0/components/blacklist_mgr/dispatcher/src/wlan_blm_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/blacklist_mgr/dispatcher/src/wlan_blm_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/ipa/dispatcher/src/wlan_ipa_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/ipa/dispatcher/src/wlan_ipa_obj_mgmt_api.o
  CC      drivers/staging/qcacld-3.0/components/ipa/dispatcher/src/wlan_ipa_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/ipa/core/src/wlan_ipa_main.o
  CC      drivers/staging/qcacld-3.0/components/ipa/core/src/wlan_ipa_core.o
  CC      drivers/staging/qcacld-3.0/components/ipa/core/src/wlan_ipa_stats.o
  CC      drivers/staging/qcacld-3.0/components/ipa/core/src/wlan_ipa_rm.o
  CC      drivers/staging/qcacld-3.0/components/disa/core/src/wlan_disa_main.o
  CC      drivers/staging/qcacld-3.0/components/disa/dispatcher/src/wlan_disa_obj_mgmt_api.o
  CC      drivers/staging/qcacld-3.0/components/disa/dispatcher/src/wlan_disa_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/disa/dispatcher/src/wlan_disa_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/components/action_oui/core/src/wlan_action_oui_main.o
  CC      drivers/staging/qcacld-3.0/components/action_oui/core/src/wlan_action_oui_parse.o
  CC      drivers/staging/qcacld-3.0/components/action_oui/dispatcher/src/wlan_action_oui_tgt_api.o
  CC      drivers/staging/qcacld-3.0/components/action_oui/dispatcher/src/wlan_action_oui_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/global_umac_dispatcher/lmac_if/src/wlan_lmac_if.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/core/src/wlan_scan_cache_db.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/core/src/wlan_scan_11d.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/core/src/wlan_scan_bss_score.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/core/src/wlan_scan_filter.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/core/src/wlan_scan_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/core/src/wlan_scan_manager.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/dispatcher/src/wlan_scan_tgt_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/dispatcher/src/wlan_scan_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/dispatcher/src/wlan_scan_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/scan/dispatcher/src/wlan_scan_utils_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/os_if/linux/scan/src/wlan_cfg80211_scan.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/os_if/linux/wlan_cfg80211.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/scan/src/target_if_scan.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/utils/src/wlan_utility.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/spectral/core/spectral_offload.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/spectral/core/spectral_common.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/spectral/dispatcher/src/wlan_spectral_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/spectral/dispatcher/src/wlan_spectral_utils_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/spectral/dispatcher/src/wlan_spectral_tgt_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/os_if/linux/spectral/src/wlan_cfg80211_spectral.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/os_if/linux/spectral/src/os_if_spectral_netlink.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/spectral/target_if_spectral_netlink.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/spectral/target_if_spectral_phyerr.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/spectral/target_if_spectral.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/spectral/target_if_spectral_sim.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/gpio/dispatcher/src/wlan_gpio_tgt_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/gpio/dispatcher/src/wlan_gpio_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/gpio/core/src/wlan_gpio_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/os_if/linux/gpio/src/wlan_cfg80211_gpio.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/gpio/target_if_gpio.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/green_ap/core/src/wlan_green_ap_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/green_ap/dispatcher/src/wlan_green_ap_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/green_ap/dispatcher/src/wlan_green_ap_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/target_if/green_ap/src/target_if_green_ap.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/crypto/src/wlan_crypto_global_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/crypto/src/wlan_crypto_ucfg_api.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/crypto/src/wlan_crypto_main.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/crypto/src/wlan_crypto_obj_mgr.o
  CC      drivers/staging/qcacld-3.0/../qca-wifi-host-cmn/umac/cmn_services/crypto/src/wlan_crypto_param_handling.o
  AR      drivers/staging/qcacld-3.0/wlan.o
  AR      drivers/staging/qcacld-3.0/built-in.a
  AR      drivers/staging/built-in.a
  AR      drivers/built-in.a
  GEN     .version
  CHK     include/generated/compile.h
  UPD     include/generated/compile.h
  CC      init/version.o
  AR      init/built-in.a
  AR      built-in.a
  LTO     vmlinux.o
  MODPOST vmlinux.o
  KSYM    .tmp_kallsyms1.o
  KSYM    .tmp_kallsyms2.o
  LD      vmlinux
  SORTEX  vmlinux
  SYSMAP  System.map
  OBJCOPY arch/arm64/boot/Image
  Building modules, stage 2.
  LD [M]  net/ipv4/tcp_bic.lto.o
  LD [M]  net/ipv4/tcp_htcp.lto.o
  MODPOST 2 modules
  CC      net/ipv4/tcp_bic.mod.o
  CC      net/ipv4/tcp_htcp.mod.o
  GZIP    arch/arm64/boot/Image.gz
  LD [M]  net/ipv4/tcp_bic.ko
  LD [M]  net/ipv4/tcp_htcp.ko
::endgroup::
::group::Checking build output
[x] expected kernel image not found: /home/runner/work/Samms_Kernel_miatoll/Samms_Kernel_miatoll/kernel_workspace/android-kernel/out/arch/arm64/boot/Image.gz-dtb
       Built files: Image Image.gz dtb.img dtbo.img dts 
       Check that KERNEL_IMAGE_NAME matches what your kernel produces.
::error::expected kernel image not found: /home/runner/work/Samms_Kernel_miatoll/Samms_Kernel_miatoll/kernel_workspace/android-kernel/out/arch/arm64/boot/Image.gz-dtb
       Built files: Image Image.gz dtb.img dtbo.img dts 
       Check that KERNEL_IMAGE_NAME matches what your kernel produces.
=== finished: 2026-11-23T02:49:50Z (rc=1)
```

## config.log

```
=== stage: config 
=== started: 2026-11-23T02:34:30Z
::group::Resolved configuration
  ADD_KPROBES_CONFIG               = false
  ADD_LOCALVERSION_TO_FILENAME     = true
  ADD_OVERLAYFS_CONFIG             = true
  ARCH                             = arm64
  BUILD_BOOT_IMG                   = false
  CLANG_BRANCH                     = master
  CLANG_VERSION                    = r547379
  CUSTOM_ANYKERNEL3_BRANCH         = 
  CUSTOM_ANYKERNEL3_SOURCE         = 
  CUSTOM_CLANG_BRANCH              = master
  CUSTOM_CLANG_SOURCE              = https://github.com/kdrag0n/proton-clang.git
  CUSTOM_CMDS                      = CLANG_TRIPLE=aarch64-linux-gnu-
  CUSTOM_GCC_32_BIN                = arm-linux-androideabi-
  CUSTOM_GCC_32_BRANCH             = 
  CUSTOM_GCC_32_SOURCE             = 
  CUSTOM_GCC_64_BIN                = aarch64-linux-android-
  CUSTOM_GCC_64_BRANCH             = 
  CUSTOM_GCC_64_SOURCE             = 
  DEVICE                           = miatoll
  DISABLE_CC_WERROR                = false
  DISABLE_LTO                      = false
  ENABLE_CCACHE                    = true
  ENABLE_GCC_ARM32                 = true
  ENABLE_GCC_ARM64                 = true
  ENABLE_HIDE_STUFF                = false
  ENABLE_KPM                       = true
  ENABLE_PATH_UMOUNT               = false
  ENABLE_SUSFS                     = false
  EXTRA_CMDS                       = LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip HOSTLDFLAGS=-B/usr/bin
  EXTRA_DEFCONFIG                  = CONFIG_LLVM_POLLY=n
  KERNEL_CONFIG                    = vendor/xiaomi/miatoll_defconfig
  KERNEL_IMAGE_NAME                = Image.gz-dtb
  KERNEL_NAME                      = miatoll
  KERNEL_SOURCE                    = https://github.com/Nihal-live/Samms_Kernel_miatoll
  KERNEL_SOURCE_BRANCH             = arena/6930beb9-samms-kernel-miatoll
  KSU_EXPECTED_HASH                = 
  KSU_EXPECTED_SIZE                = 
  KSU_HOOK_MODE                    = none
  KSU_REF                          = 4bec532dd447e2852aa8932afa768255350c103a
  KSU_VARIANT                      = samms-nova
  NEED_DTBO                        = false
  REMOVE_UNUSED_PACKAGES           = true
  SOURCE_BOOT_IMAGE                = 
  SUSFS_BRANCH                     = auto
  SUSFS_REPO                       = https://gitlab.com/simonpunk/susfs4ksu.git
  USE_CUSTOM_ANYKERNEL3            = false
  USE_CUSTOM_CLANG                 = true
  USE_CUSTOM_GCC_32                = false
  USE_CUSTOM_GCC_64                = false
  USE_LLVM                         = false
::endgroup::
[+] configuration resolved (device: miatoll)
=== finished: 2026-11-23T02:34:30Z (rc=0)
```

## kernelsu.log

```
=== stage: kernelsu 
=== started: 2026-11-23T02:38:39Z
::group::Installing SukiSU-Nova (in-tree)
[*] running the in-tree integration: scripts/ksu-nova-setup.sh
[*] kernel 4.14; the in-tree script refuses anything but the version
[*] it was written for, so a mismatch fails here instead of at link time
[ksu-nova]   ok: kernel 4.14, defconfig arch/arm64/configs/vendor/xiaomi/miatoll_defconfig
[ksu-nova]   ok: ref '4bec532dd447e2852aa8932afa768255350c103a' is a pinned commit (validated by the fetch)
[ksu-nova] fetching SukiSU-Nova (4bec532dd447e2852aa8932afa768255350c103a)
[ksu-nova]   ok: SukiSU-Nova checked out at 4bec532dd447e2852aa8932afa768255350c103a
[ksu-nova] creating drivers/kernelsu -> ../KernelSU/kernel
[ksu-nova] wiring drivers/Makefile
[ksu-nova] wiring drivers/Kconfig
[ksu-nova]   ok: drivers/Makefile + drivers/Kconfig wired
[ksu-nova]   guarded linux/static_call.h include for < 5.10
[ksu-nova]   KPM guard already >= 4.4
[ksu-nova]   ported access_ok() to the pre-5.0 form
[ksu-nova]   added the pre-4.17 truncate-handler lookup
[ksu-nova]   defined __NR_truncate for arm64
[ksu-nova]   task_struct pid member honours KSU_TASK_HAS_THREAD_PID
<stdin>:11: SyntaxWarning: "\*" is an invalid escape sequence. Such sequences will not work in the future. Did you mean "\\*"? A raw string is also an option.
[ksu-nova]   added KSU_TASK_HAS_THREAD_PID probe to the clone Makefile
[ksu-nova]   lowered cpu_spoof guard from 5.10.0 to 4.14.0
[ksu-nova]   guarded the vDSO datapage include
[ksu-nova]   guarded the elf_hwcap2 write
[ksu-nova]   guarded the >= 4.18 vDSO / clocksource / hwcap writes
[ksu-nova]   closed the >= 4.18 guard
[ksu-nova]   patched fs/exec.c do_execveat_common -> ksu_handle_execveat()
[ksu-nova]   patched kernel/reboot.c reboot -> ksu_handle_sys_reboot()
[ksu-nova]   skip: kernel/sys.c setresuid -> ksu_handle_setresuid() -- ksu_handle_setresuid is not defined in this configuration
[ksu-nova]   patched drivers/input/input.c input_handle_event -> ksu_handle_input_handle_event()
[ksu-nova]   patched fs/open.c faccessat -> ksu_handle_faccessat()
[ksu-nova]   patched fs/stat.c vfs_statx -> ksu_handle_stat()
[ksu-nova]   note: skipped hooks for ksu_handle_setresuid (not built without CONFIG_KSU_SUSFS)
[ksu-nova]   ok: manual hook call sites in place (5 files)
[ksu-nova]   defconfig: SukiSU-Nova block written (6 symbol(s))
[ksu-nova]   ok: defconfig: CONFIG_KSU=y, ADB root on, KPM on, no SUSFS symbols

[ksu-nova] integration complete
[ksu-nova]   SukiSU-Nova : 4bec532dd447e2852aa8932afa768255350c103a
[ksu-nova]   defconfig   : arch/arm64/configs/vendor/xiaomi/miatoll_defconfig
[ksu-nova]   features    : su compat, kernel umount, sulog, adb root,
[ksu-nova]                 shell su adb only, mount hide, cpu identity spoof,
[ksu-nova]                 KPM (CONFIG_KPM=y; the built Image must still be
[ksu-nova]                 post-processed by KernelPatch's patch_linux)
[ksu-nova]                 (manager-toggled; compiled in unconditionally)
[ksu-nova]   not included: SUSFS, selinux hide (needs 5.6+ SELinux internals),
[ksu-nova]                 AVC log spoofing (SUSFS-only)
[ksu-nova]   next        : scripts/build.sh --clang-dir <clang>/bin
[ksu-nova]   note        : CONFIG_KSU must still be =y in out/.config after
[ksu-nova]                 'make olddefconfig'; the workflow asserts that,
[ksu-nova]                 because an option whose dependency is unmet is
[ksu-nova]                 dropped silently.
[+] SukiSU-Nova (in-tree) installed at 4bec532 (4bec532)
[*] hook mode: none (the in-tree script patches the call sites itself)
::endgroup::
=== finished: 2026-11-23T02:38:40Z (rc=0)
```

## patches.log

```
=== stage: patches all
=== started: 2026-11-23T02:38:40Z
=== finished: 2026-11-23T02:38:40Z (rc=0)
```

## source.log

```
=== stage: source 
=== started: 2026-11-23T02:38:27Z
::group::Cloning kernel source
[*] https://github.com/Nihal-live/Samms_Kernel_miatoll @ arena/6930beb9-samms-kernel-miatoll
[d] kernel tree is shallow; that is fine for building
[+] kernel source ready (Linux 4.14)
::endgroup::
=== finished: 2026-11-23T02:38:39Z (rc=0)
```

## toolchain.log

```
=== stage: toolchain 
=== started: 2026-11-23T02:36:45Z
::group::Downloading custom Clang
[+] clang ready: Proton clang version 13.0.0 (https://github.com/llvm/llvm-project b4fd512c36ca344a3ff69350219e8b0a67e9472a)
::endgroup::
::group::Downloading AOSP GCC (arm64)
[*] fetching https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/tags/android-12.1.0_r27.tar.gz
::endgroup::
::group::Downloading AOSP GCC (arm32)
[*] fetching https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/tags/android-12.1.0_r27.tar.gz
::endgroup::
=== finished: 2026-11-23T02:38:27Z (rc=0)
```
