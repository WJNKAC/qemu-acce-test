/*
 * HMP commands related to UI
 *
 * Copyright IBM, Corp. 2011
 *
 * Authors:
 *  Anthony Liguori   <aliguori@us.ibm.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2.  See
 * the COPYING file in the top-level directory.
 *
 * Contributions after 2012-01-13 are licensed under the terms of the
 * GNU GPL, version 2 or (at your option) any later version.
 */

#include "qemu/osdep.h"
#ifdef CONFIG_SPICE
#include <spice/enums.h>
#endif
#include "monitor/hmp.h"
#include "monitor/hmp-completion.h"
#include "monitor/monitor-internal.h"
#include "qapi/error.h"
#include "qapi/qapi-commands-ui.h"
#include "qobject/qdict.h"
#include "qemu/cutils.h"
#include "ui/console.h"
#include "ui/input.h"
#include "hw/core/cpu.h"
#include "system/henge-accel.h"
#include "system/henge-engine.h"

static int mouse_button_state;

void hmp_mouse_move(Monitor *mon, const QDict *qdict)
{
    int dx, dy, dz, button;
    const char *dx_str = qdict_get_str(qdict, "dx_str");
    const char *dy_str = qdict_get_str(qdict, "dy_str");
    const char *dz_str = qdict_get_try_str(qdict, "dz_str");

    dx = strtol(dx_str, NULL, 0);
    dy = strtol(dy_str, NULL, 0);
    qemu_input_queue_rel(NULL, INPUT_AXIS_X, dx);
    qemu_input_queue_rel(NULL, INPUT_AXIS_Y, dy);

    if (dz_str) {
        dz = strtol(dz_str, NULL, 0);
        if (dz != 0) {
            button = (dz > 0) ? INPUT_BUTTON_WHEEL_UP : INPUT_BUTTON_WHEEL_DOWN;
            qemu_input_queue_btn(NULL, button, true);
            qemu_input_event_sync();
            qemu_input_queue_btn(NULL, button, false);
        }
    }
    qemu_input_event_sync();
}

/*
 * mouse_abs x y —— 把光标放到**绝对屏幕坐标** (x, y)。
 *
 * 为什么需要它：HMP 原有的 mouse_move 走的是 qemu_input_queue_rel()，
 * 参数是**相对位移量**而非坐标（见 hmp_mouse_move 实现）。
 * 用它去"点某个控件"必须自己累积偏移，而且一旦累计错了就无法纠正 ——
 * 实测想点列表第 5 项，多发几次后光标永远停在末尾。
 *
 * 绝对坐标只有 QMP 的 input-send-event 能做，但 HMP 里没有对应命令
 * （本二进制也未编入 input-send-event）。所以这里补一条。
 *
 * 坐标用**屏幕像素**，内部按当前 console 分辨率缩放到 0..0x7FFF，
 * 这样调用方不需要知道 QEMU 内部的定标。
 */
void hmp_mouse_abs(Monitor *mon, const QDict *qdict)
{
    QemuConsole *con = qemu_console_lookup_default();
    int x = qdict_get_int(qdict, "x");
    int y = qdict_get_int(qdict, "y");
    int w, h;

    if (!con) {
        monitor_printf(mon, "no graphical console\n");
        return;
    }

    w = qemu_console_get_width(con, 0);
    h = qemu_console_get_height(con, 0);
    if (w <= 0 || h <= 0) {
        monitor_printf(mon, "console has no size yet (%dx%d)\n", w, h);
        return;
    }

    /* 夹到 [0, w-1] / [0, h-1]，越界不报错但也不越界送 */
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > w - 1) x = w - 1;
    if (y > h - 1) y = h - 1;

    qemu_input_queue_abs(con, INPUT_AXIS_X, x, 0, w - 1);
    qemu_input_queue_abs(con, INPUT_AXIS_Y, y, 0, h - 1);
    qemu_input_event_sync();

    monitor_printf(mon, "mouse_abs %d %d (console %dx%d)\n", x, y, w, h);
}

/*
 * The interrupt join, both sides at once.
 *
 * henge_sync_irq() copies CPUState.interrupt_request's HARD/FIQ bits into the
 * engine's two level bytes, and hv_engine_set_irq() is the only writer.  TCG
 * would also clear those bits in arm_cpu_exec_interrupt() after delivering;
 * henge delivers inside its own run loop, so nothing on this path ever clears
 * them -- and nothing lowers the level unless a sync happens to run.
 *
 * A guest that stops acking therefore leaves the engine holding a level of 1
 * with no future event that could refresh it: WFI returns immediately, the run
 * loop keeps going, hv_run() never comes back out, and the vCPU burns a core
 * while the guest makes no progress.  Printing both sides is what separates
 * that from a driver genuinely holding the line high.
 */
void hmp_henge_irq(Monitor *mon, const QDict *qdict)
{
    CPUState *cs;
    int any = 0;

    monitor_printf(mon, "cpu halted  qemu   engine   pstate     pc\n");

    CPU_FOREACH(cs) {
        int qirq = -1, qfiq = -1, eirq = -1, efiq = -1;
        uint64_t pc = 0, daif = 0, el = 0;

        henge_irq_report(cs, &qirq, &qfiq);
        if (cs->opaque) {
            eirq = hv_engine_get_irq((HvCpu *)cs->opaque, 0);
            efiq = hv_engine_get_irq((HvCpu *)cs->opaque, 1);
            hv_engine_get_cpu_state((HvCpu *)cs->opaque, &pc, &daif, &el);
        }

        monitor_printf(mon, "%3d %6d  %d/%d    %d/%d    el%llu I=%d  %016llx  ",
                       cs->cpu_index, cs->halted, qirq, qfiq, eirq, efiq,
                       (unsigned long long)el,
                       !!(daif & (1u << 7)),
                       (unsigned long long)pc);
        /*
         * park/wake counters: taken as a snapshot, so two samples a few seconds
         * apart answer the only question that matters when the guest stops
         * moving -- is it parked and never woken, or never parked at all.
         */
        {
            unsigned ci = cs->cpu_index < 8 ? cs->cpu_index : 0;
            monitor_printf(mon, "park %llu/%llu wake %llu  in-park %lld",
                           (unsigned long long)hv_spike_park_enter[ci],
                           (unsigned long long)hv_spike_park_leave[ci],
                           (unsigned long long)hv_spike_wake[ci],
                           (long long)(hv_spike_park_enter[ci]
                                       - hv_spike_park_leave[ci]));
        }
        if (!cs->opaque) {
            monitor_printf(mon, "no engine state\n");
        } else if (eirq != qirq || efiq != qfiq) {
            monitor_printf(mon, "STALE: engine holds a level QEMU dropped\n");
            any = 1;
        } else if ((qirq == 1 || qfiq == 1) && !(daif & (1u << 7))) {
            /* The interesting case: line asserted, interrupts unmasked, and the
             * guest still not taking it.  That is a delivery problem, not a
             * stale copy, and it is what turns WFI into a spin. */
            monitor_printf(mon, "ASSERTED+UNMASKED: should have been delivered\n");
            any = 1;
        } else if (qirq == 1 || qfiq == 1) {
            monitor_printf(mon, "asserted, but PSTATE.I masks it\n");
        } else {
            monitor_printf(mon, "in sync, lines low\n");
        }
    }

    if (any) {
        monitor_printf(mon, "\nA line the engine sees but the guest never takes means WFI "
                            "can never block: the vCPU spins at full host speed.\n");
    }
}

void hmp_mouse_button(Monitor *mon, const QDict *qdict)
{
    /* HMP mouse_button bitmask: 1=L, 2=R, 4=M */
    static uint32_t bmap[INPUT_BUTTON__MAX] = {
        [INPUT_BUTTON_LEFT]       = 0x01,
        [INPUT_BUTTON_MIDDLE]     = 0x04,
        [INPUT_BUTTON_RIGHT]      = 0x02,
    };
    int button_state = qdict_get_int(qdict, "button_state");

    if (mouse_button_state == button_state) {
        return;
    }
    qemu_input_update_buttons(NULL, bmap, mouse_button_state, button_state);
    qemu_input_event_sync();
    mouse_button_state = button_state;
}

void hmp_mouse_set(Monitor *mon, const QDict *qdict)
{
    Error *err = NULL;

    qemu_mouse_set(qdict_get_int(qdict, "index"), &err);
    hmp_handle_error(mon, err);
}

void hmp_info_mice(Monitor *mon, const QDict *qdict)
{
    MouseInfoList *mice_list, *mouse;

    mice_list = qmp_query_mice(NULL);
    if (!mice_list) {
        monitor_printf(mon, "No mouse devices connected\n");
        return;
    }

    for (mouse = mice_list; mouse; mouse = mouse->next) {
        monitor_printf(mon, "%c Mouse #%" PRId64 ": %s%s\n",
                       mouse->value->current ? '*' : ' ',
                       mouse->value->index, mouse->value->name,
                       mouse->value->absolute ? " (absolute)" : "");
    }

    qapi_free_MouseInfoList(mice_list);
}

#ifdef CONFIG_VNC
/* Helper for hmp_info_vnc_clients, _servers */
static void hmp_info_VncBasicInfo(Monitor *mon, VncBasicInfo *info,
                                  const char *name)
{
    monitor_printf(mon, "  %s: %s:%s (%s%s)\n",
                   name,
                   info->host,
                   info->service,
                   NetworkAddressFamily_str(info->family),
                   info->websocket ? " (Websocket)" : "");
}

/* Helper displaying and auth and crypt info */
static void hmp_info_vnc_authcrypt(Monitor *mon, const char *indent,
                                   VncPrimaryAuth auth,
                                   VncVencryptSubAuth *vencrypt)
{
    monitor_printf(mon, "%sAuth: %s (Sub: %s)\n", indent,
                   VncPrimaryAuth_str(auth),
                   vencrypt ? VncVencryptSubAuth_str(*vencrypt) : "none");
}

static void hmp_info_vnc_clients(Monitor *mon, VncClientInfoList *client)
{
    while (client) {
        VncClientInfo *cinfo = client->value;

        hmp_info_VncBasicInfo(mon, qapi_VncClientInfo_base(cinfo), "Client");
        monitor_printf(mon, "    x509_dname: %s\n",
                       cinfo->x509_dname ?: "none");
        monitor_printf(mon, "    sasl_username: %s\n",
                       cinfo->sasl_username ?: "none");

        client = client->next;
    }
}

static void hmp_info_vnc_servers(Monitor *mon, VncServerInfo2List *server)
{
    while (server) {
        VncServerInfo2 *sinfo = server->value;
        hmp_info_VncBasicInfo(mon, qapi_VncServerInfo2_base(sinfo), "Server");
        hmp_info_vnc_authcrypt(mon, "    ", sinfo->auth,
                               sinfo->has_vencrypt ? &sinfo->vencrypt : NULL);
        server = server->next;
    }
}

void hmp_info_vnc(Monitor *mon, const QDict *qdict)
{
    VncInfo2List *info2l, *info2l_head;
    Error *err = NULL;

    info2l = qmp_query_vnc_servers(&err);
    info2l_head = info2l;
    if (hmp_handle_error(mon, err)) {
        return;
    }
    if (!info2l) {
        monitor_printf(mon, "None\n");
        return;
    }

    while (info2l) {
        VncInfo2 *info = info2l->value;
        monitor_printf(mon, "%s:\n", info->id);
        hmp_info_vnc_servers(mon, info->server);
        hmp_info_vnc_clients(mon, info->clients);
        if (!info->server) {
            /*
             * The server entry displays its auth, we only need to
             * display in the case of 'reverse' connections where
             * there's no server.
             */
            hmp_info_vnc_authcrypt(mon, "  ", info->auth,
                               info->has_vencrypt ? &info->vencrypt : NULL);
        }
        if (info->display) {
            monitor_printf(mon, "  Display: %s\n", info->display);
        }
        info2l = info2l->next;
    }

    qapi_free_VncInfo2List(info2l_head);

}
#endif

#ifdef CONFIG_SPICE
void hmp_info_spice(Monitor *mon, const QDict *qdict)
{
    SpiceChannelList *chan;
    SpiceInfo *info;
    const char *channel_name;
    static const char *const channel_names[] = {
        [SPICE_CHANNEL_MAIN] = "main",
        [SPICE_CHANNEL_DISPLAY] = "display",
        [SPICE_CHANNEL_INPUTS] = "inputs",
        [SPICE_CHANNEL_CURSOR] = "cursor",
        [SPICE_CHANNEL_PLAYBACK] = "playback",
        [SPICE_CHANNEL_RECORD] = "record",
        [SPICE_CHANNEL_TUNNEL] = "tunnel",
        [SPICE_CHANNEL_SMARTCARD] = "smartcard",
        [SPICE_CHANNEL_USBREDIR] = "usbredir",
        [SPICE_CHANNEL_PORT] = "port",
        [SPICE_CHANNEL_WEBDAV] = "webdav",
    };

    info = qmp_query_spice(NULL);

    if (!info->enabled) {
        monitor_printf(mon, "Server: disabled\n");
        goto out;
    }

    monitor_printf(mon, "Server:\n");
    if (info->has_port) {
        monitor_printf(mon, "     address: %s:%" PRId64 "\n",
                       info->host, info->port);
    }
    if (info->has_tls_port) {
        monitor_printf(mon, "     address: %s:%" PRId64 " [tls]\n",
                       info->host, info->tls_port);
    }
    monitor_printf(mon, "    migrated: %s\n",
                   info->migrated ? "true" : "false");
    monitor_printf(mon, "        auth: %s\n", info->auth);
    monitor_printf(mon, "    compiled: %s\n", info->compiled_version);
    monitor_printf(mon, "  mouse-mode: %s\n",
                   SpiceQueryMouseMode_str(info->mouse_mode));

    if (!info->has_channels || info->channels == NULL) {
        monitor_printf(mon, "Channels: none\n");
    } else {
        for (chan = info->channels; chan; chan = chan->next) {
            monitor_printf(mon, "Channel:\n");
            monitor_printf(mon, "     address: %s:%s%s\n",
                           chan->value->host, chan->value->port,
                           chan->value->tls ? " [tls]" : "");
            monitor_printf(mon, "     session: %" PRId64 "\n",
                           chan->value->connection_id);
            monitor_printf(mon, "     channel: %" PRId64 ":%" PRId64 "\n",
                           chan->value->channel_type, chan->value->channel_id);

            channel_name = "unknown";
            if (chan->value->channel_type > 0 &&
                chan->value->channel_type < ARRAY_SIZE(channel_names) &&
                channel_names[chan->value->channel_type]) {
                channel_name = channel_names[chan->value->channel_type];
            }

            monitor_printf(mon, "     channel name: %s\n", channel_name);
        }
    }

out:
    qapi_free_SpiceInfo(info);
}
#endif

void hmp_set_password(Monitor *mon, const QDict *qdict)
{
    const char *protocol  = qdict_get_str(qdict, "protocol");
    const char *password  = qdict_get_str(qdict, "password");
    const char *display = qdict_get_try_str(qdict, "display");
    const char *connected = qdict_get_try_str(qdict, "connected");
    Error *err = NULL;

    SetPasswordOptions opts = {
        .password = (char *)password,
        .has_connected = !!connected,
    };

    opts.connected = qapi_enum_parse(&SetPasswordAction_lookup, connected,
                                     SET_PASSWORD_ACTION_KEEP, &err);
    if (err) {
        goto out;
    }

    opts.protocol = qapi_enum_parse(&DisplayProtocol_lookup, protocol,
                                    DISPLAY_PROTOCOL_VNC, &err);
    if (err) {
        goto out;
    }

    if (opts.protocol == DISPLAY_PROTOCOL_VNC) {
        opts.u.vnc.display = (char *)display;
    }

    qmp_set_password(&opts, &err);

out:
    hmp_handle_error(mon, err);
}

void hmp_expire_password(Monitor *mon, const QDict *qdict)
{
    const char *protocol  = qdict_get_str(qdict, "protocol");
    const char *whenstr = qdict_get_str(qdict, "time");
    const char *display = qdict_get_try_str(qdict, "display");
    Error *err = NULL;

    ExpirePasswordOptions opts = {
        .time = (char *)whenstr,
    };

    opts.protocol = qapi_enum_parse(&DisplayProtocol_lookup, protocol,
                                    DISPLAY_PROTOCOL_VNC, &err);
    if (err) {
        goto out;
    }

    if (opts.protocol == DISPLAY_PROTOCOL_VNC) {
        opts.u.vnc.display = (char *)display;
    }

    qmp_expire_password(&opts, &err);

out:
    hmp_handle_error(mon, err);
}

#ifdef CONFIG_VNC
static void hmp_change_read_arg(void *opaque, const char *password,
                                void *readline_opaque)
{
    qmp_change_vnc_password(password, NULL);
    monitor_read_command(opaque, 1);
}

void hmp_change_vnc(Monitor *mon, const char *device, const char *target,
                    const char *arg, const char *read_only, bool force,
                    Error **errp)
{
    if (read_only) {
        error_setg(errp, "Parameter 'read-only-mode' is invalid for VNC");
        return;
    }
    if (strcmp(target, "passwd") && strcmp(target, "password")) {
        error_setg(errp, "Expected 'password' after 'vnc'");
        return;
    }
    if (!arg) {
        MonitorHMP *hmp_mon = container_of(mon, MonitorHMP, parent_obj);
        monitor_read_password(hmp_mon, hmp_change_read_arg, NULL);
    } else {
        qmp_change_vnc_password(arg, errp);
    }
}
#endif

static int index_from_key(const char *key, size_t key_length)
{
    int i;

    for (i = 0; i < Q_KEY_CODE__MAX; i++) {
        if (!strncmp(key, QKeyCode_str(i), key_length) &&
            !QKeyCode_str(i)[key_length]) {
            break;
        }
    }

    /* Return Q_KEY_CODE__MAX if the key is invalid */
    return i;
}

void hmp_sendkey(Monitor *mon, const QDict *qdict)
{
    const char *keys = qdict_get_str(qdict, "keys");
    KeyValue *v = NULL;
    KeyValueList *head = NULL, **tail = &head;
    int has_hold_time = qdict_haskey(qdict, "hold-time");
    int hold_time = qdict_get_try_int(qdict, "hold-time", -1);
    Error *err = NULL;
    const char *separator;
    int keyname_len;

    while (1) {
        separator = qemu_strchrnul(keys, '-');
        keyname_len = separator - keys;

        /* Be compatible with old interface, convert user inputted "<" */
        if (keys[0] == '<' && keyname_len == 1) {
            keys = "less";
            keyname_len = 4;
        }

        v = g_malloc0(sizeof(*v));

        if (strstart(keys, "0x", NULL)) {
            const char *endp;
            int value;

            if (qemu_strtoi(keys, &endp, 0, &value) < 0) {
                goto err_out;
            }
            assert(endp <= keys + keyname_len);
            if (endp != keys + keyname_len) {
                goto err_out;
            }
            v->type = KEY_VALUE_KIND_NUMBER;
            v->u.number.data = value;
        } else {
            int idx = index_from_key(keys, keyname_len);
            if (idx == Q_KEY_CODE__MAX) {
                goto err_out;
            }
            v->type = KEY_VALUE_KIND_QCODE;
            v->u.qcode.data = idx;
        }
        QAPI_LIST_APPEND(tail, v);
        v = NULL;

        if (!*separator) {
            break;
        }
        keys = separator + 1;
    }

    qmp_send_key(head, has_hold_time, hold_time, &err);
    hmp_handle_error(mon, err);

out:
    qapi_free_KeyValue(v);
    qapi_free_KeyValueList(head);
    return;

err_out:
    monitor_printf(mon, "invalid parameter: %.*s\n", keyname_len, keys);
    goto out;
}

void sendkey_completion(ReadLineState *rs, int nb_args, const char *str)
{
    int i;
    const char *sep;
    size_t len;

    if (nb_args != 2) {
        return;
    }
    sep = strrchr(str, '-');
    if (sep) {
        str = sep + 1;
    }
    len = strlen(str);
    readline_set_completion_index(rs, len);
    for (i = 0; i < Q_KEY_CODE__MAX; i++) {
        if (!strncmp(str, QKeyCode_str(i), len)) {
            readline_add_completion(rs, QKeyCode_str(i));
        }
    }
}

#ifdef CONFIG_PIXMAN
void coroutine_fn
hmp_screendump(Monitor *mon, const QDict *qdict)
{
    const char *filename = qdict_get_str(qdict, "filename");
    const char *id = qdict_get_try_str(qdict, "device");
    int64_t head = qdict_get_try_int(qdict, "head", 0);
    const char *input_format  = qdict_get_try_str(qdict, "format");
    Error *err = NULL;
    ImageFormat format;

    format = qapi_enum_parse(&ImageFormat_lookup, input_format,
                              IMAGE_FORMAT_PPM, &err);
    if (err) {
        goto end;
    }

    qmp_screendump(filename, id, id != NULL, head,
                   input_format != NULL, format, &err);
end:
    hmp_handle_error(mon, err);
}
#endif

void hmp_client_migrate_info(Monitor *mon, const QDict *qdict)
{
    Error *err = NULL;
    const char *protocol = qdict_get_str(qdict, "protocol");
    const char *hostname = qdict_get_str(qdict, "hostname");
    bool has_port        = qdict_haskey(qdict, "port");
    int port             = qdict_get_try_int(qdict, "port", -1);
    bool has_tls_port    = qdict_haskey(qdict, "tls-port");
    int tls_port         = qdict_get_try_int(qdict, "tls-port", -1);
    const char *cert_subject = qdict_get_try_str(qdict, "cert-subject");

    qmp_client_migrate_info(protocol, hostname,
                            has_port, port, has_tls_port, tls_port,
                            cert_subject, &err);
    hmp_handle_error(mon, err);
}
