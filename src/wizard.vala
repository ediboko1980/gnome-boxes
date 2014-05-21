// This file is part of GNOME Boxes. License: LGPLv2+

private enum Boxes.WizardPage {
    INTRODUCTION,
    SOURCE,
    PREPARATION,
    SETUP,
    REVIEW,

    LAST,
}

[GtkTemplate (ui = "/org/gnome/Boxes/ui/wizard.ui")]
private class Boxes.Wizard: Gtk.Stack, Boxes.UI {
    private const string[] page_names = { "introduction", "source", "preparation", "setup", "review" };

    public UIState previous_ui_state { get; protected set; }
    public UIState ui_state { get; protected set; }

    private Gtk.Button cancel_button;
    private Gtk.Button back_button;
    private Gtk.Button next_button;
    private Gtk.Button continue_button;
    private Gtk.Button create_button;
    private CollectionSource? source;

    [GtkChild]
    private Boxes.WizardSource wizard_source;
    [GtkChild]
    private WizardSummary summary;
    [GtkChild]
    private Gtk.ProgressBar prep_progress;
    [GtkChild]
    private Gtk.Label prep_media_label;
    [GtkChild]
    private Gtk.Label prep_status_label;
    [GtkChild]
    private Gtk.Box setup_box;
    [GtkChild]
    private Gtk.Label review_label;
    [GtkChild]
    private Gtk.InfoBar nokvm_infobar;
    [GtkChild]
    private Gtk.Image installer_image;

    private MediaManager media_manager;

    private VMCreator? vm_creator;
    protected Machine? machine { get; set; }
    private LibvirtMachine? libvirt_machine { get { return (machine as LibvirtMachine); } }

    private WizardPage _page;
    public WizardPage page {
        get { return _page; }
        private set {
            back_button.sensitive = (value != WizardPage.INTRODUCTION);

            var forwards = value > page;

            switch (value) {
            case WizardPage.INTRODUCTION:
                create_button.visible = false;
                continue_button.visible = true;
                next_button = continue_button;
                next_button.sensitive = true;
                next_button.grab_focus ();
                break;

            case WizardPage.SOURCE:
                // reset page to notify deeply widgets states
                wizard_source.page = wizard_source.page;
                cleanup ();
                break;
            }

            if (forwards) {
                switch (value) {
                case WizardPage.SOURCE:
                    wizard_source.page = SourcePage.MAIN;
                    break;

                case WizardPage.PREPARATION:
                    if (!prepare ())
                        return;
                    break;

                case WizardPage.SETUP:
                    if (!setup ())
                        return;
                    break;

                case WizardPage.REVIEW:
                    continue_button.visible = false;
                    create_button.visible = true;
                    next_button = create_button;
                    next_button.sensitive = false;

                    review.begin ((obj, result) => {
                        next_button.sensitive = true;
                        create_button.grab_focus ();
                        if (!review.end (result))
                            page = page - 1;
                    });
                    break;

                case WizardPage.LAST:
                    create.begin ((obj, result) => {
                       if (create.end (result))
                          App.app.set_state (UIState.COLLECTION);
                       else
                          App.window.notificationbar.display_error (_("Box creation failed"));
                    });
                    return;
                }
            } else {
                switch (page) {
                case WizardPage.REVIEW:
                    create_button.visible = false;
                    continue_button.visible = true;
                    next_button = continue_button;
                    destroy_machine ();
                    break;
                }
            }

            if (skip_page (value))
                return;

            _page = value;
            App.window.sidebar.set_wizard_page (value);
            visible_child_name = page_names[value];

            if (value == WizardPage.SOURCE)
                wizard_source_update_next ();
        }
    }

    private void wizard_source_update_next () {
        if (page != WizardPage.SOURCE)
            return;

        next_button.sensitive = false;

        switch (wizard_source.page) {
        case Boxes.SourcePage.MAIN:
            next_button.sensitive = wizard_source.selected != null;
            source = null;
            break;

        case Boxes.SourcePage.URL:
            next_button.sensitive = wizard_source.uri.length != 0;

            var text = _("Please enter desktop or collection URI");
            var icon = "preferences-desktop-remote-desktop";
            try {
                prepare_for_location (this.wizard_source.uri, true);

                if (source != null && App.app.has_broker_for_source_type (source.source_type)) {
                    text = _("Will add boxes for all systems available from this account.");
                    icon = "network-workgroup";
                } else
                    text = _("Will add a single box.");

            } catch (GLib.Error error) {
                // ignore any parsing error
            }

            wizard_source.update_url_page (_("Desktop Access"), text, icon);
            break;

        default:
            warn_if_reached ();
            break;
        }
    }

   construct {
        media_manager = MediaManager.get_instance ();
        wizard_source.notify["page"].connect(wizard_source_update_next);
        wizard_source.notify["selected"].connect(wizard_source_update_next);
        wizard_source.url_entry.changed.connect (wizard_source_update_next);
        notify["ui-state"].connect (ui_state_changed);

        wizard_source.activated.connect(() => {
            page = WizardPage.PREPARATION;
        });

        // FIXME: Why this won't work from .ui file?
        transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
    }

    public void cleanup () {
        destroy_machine ();
        vm_creator = null;
        source = null;
        wizard_source.cleanup ();
    }

    private async bool create () {
        if (vm_creator != null) {
            if (libvirt_machine == null) {
                return_val_if_fail (review_cancellable != null, false);
                // wait until the machine is ready or not
                var wait = notify["machine"].connect (() => {
                   create.callback ();
                });
                yield;
                disconnect (wait);
                if (libvirt_machine == null)
                    return false;
            }
            next_button.sensitive = false;
            try {
                vm_creator.launch_vm (libvirt_machine);
            } catch (GLib.Error error) {
                warning (error.message);

                return false;
            }

            vm_creator.install_media.clean_up_preparation_cache ();
            vm_creator = null;
            wizard_source.uri = "";
            wizard_source.libvirt_sys_import = false;
        } else if (source != null) {
            source.save ();
            App.app.add_collection_source.begin (source);
        } else if (wizard_source.libvirt_sys_import) {
            wizard_source.libvirt_sys_importer.import.begin ();
        } else {
            return_val_if_reached (false); // Shouldn't arrive here with no source
        }

        machine = null;
        return true;
    }

    private void prepare_for_location (string location, bool probing = false) throws GLib.Error {
        if (location == "")
            throw new Boxes.Error.INVALID ("empty location");

        var file = location.contains ("://")? File.new_for_uri (location) : File.new_for_path (location);
        var path = file.get_path ();

        if (path != null && (file.has_uri_scheme ("file") || file.has_uri_scheme ("smb"))) {
            // FIXME: We should able to handle non-local URIs here too
            if (!probing)
                prepare_for_installer (path);
        } else {
            bool uncertain;
            var uri = file.get_uri ();

            var mimetype = ContentType.guess (uri, null, out uncertain);

            if (uncertain)
                prepare_for_uri (uri);
            else {
                debug ("Can't handle remote location '%s' (mime type: '%s')",
                        uri,
                        ContentType.get_mime_type (mimetype));
                throw new Boxes.Error.INVALID (_("Invalid URI"));
            }
        }
    }

    private void prepare_for_uri (string uri_as_text) throws Boxes.Error {
        var uri = Xml.URI.parse (uri_as_text);

        if (uri == null || uri.scheme == null)
            throw new Boxes.Error.INVALID (_("Invalid URI"));

        source = new CollectionSource (uri.server ?? uri_as_text, uri.scheme, uri_as_text);

        if (uri.scheme == "spice") {
            spice_validate_uri (uri_as_text);
        } else if (uri.scheme == "vnc") {
            // accept any vnc:// uri
        } else if (uri.scheme.has_prefix ("qemu")) {
            // accept any qemu..:// uri
            source.source_type = "libvirt";
        } else if (App.app.has_broker_for_source_type (uri.scheme)) {
            source.source_type = uri.scheme;
        } else
            throw new Boxes.Error.INVALID (_("Unsupported protocol '%s'").printf (uri.scheme));
    }

    private void prepare_for_installer (string path) throws GLib.Error {
        next_button.sensitive = false;

        prep_media_label.label = _("Unknown installer media");
        prep_status_label.label = _("Analyzing..."); // Translators: Analyzing installer media

        media_manager.create_installer_media_for_path.begin (path, null, on_installer_media_instantiated);
    }

    private void on_installer_media_instantiated (Object? source_object, AsyncResult result) {
        try {
            var install_media = media_manager.create_installer_media_for_path.end (result);
            prepare_media.begin (install_media);
        } catch (IOError.CANCELLED cancel_error) { // We did this, so no warning!
        } catch (GLib.Error error) {
            debug("Failed to analyze installer image: %s", error.message);
            var msg = _("Failed to analyze installer media. Corrupted or incomplete media?");
            App.window.notificationbar.display_error (msg);
            page = WizardPage.SOURCE;
        }
    }

    private async void prepare_media (InstallerMedia install_media) {
        if (install_media.os != null) {
            prep_media_label.label = install_media.os.name;
            Downloader.fetch_os_logo.begin (installer_image, install_media.os, 128);
        }

        var progress = new ActivityProgress ();
        progress.notify["progress"].connect (() => {
            if (progress.progress - prep_progress.fraction >= 0.01) // Only entertain >= 1% change
                prep_progress.fraction = progress.progress;
        });
        progress.bind_property ("info", prep_status_label, "label");

        yield install_media.prepare (progress, null);

        vm_creator = install_media.get_vm_creator ();
        prep_progress.fraction = 1.0;
        page = WizardPage.SETUP;
    }

    private bool prepare () {
        installer_image.set_from_icon_name ("media-optical", 0); // Reset

        if (this.wizard_source.install_media != null) {
            prep_media_label.label = _("Unknown installer media");
            prep_status_label.label = _("Analyzing...");
            prepare_media.begin (wizard_source.install_media);
            return true;
        } else if (this.wizard_source.libvirt_sys_import) {
            return true;
        } else {
            try {
                prepare_for_location (this.wizard_source.uri);
            } catch (GLib.Error error) {
                App.window.notificationbar.display_error (error.message);

                return false;
            }

            return true;
        }
    }

    private bool setup () {
        // there is no setup yet for direct source nor libvirt system imports
        if (source != null || this.wizard_source.libvirt_sys_import)
            return true;

        return_if_fail (vm_creator != null);

        vm_creator.install_media.bind_property ("ready-to-create",
                                                continue_button, "sensitive",
                                                BindingFlags.SYNC_CREATE);
        vm_creator.install_media.populate_setup_box (setup_box);
        vm_creator.install_media.user_wants_to_create.connect (() => {
            if (vm_creator.install_media.ready_to_create)
                page = page + 1;
        });

        return true;
    }

    private Cancellable? review_cancellable;

    private async bool review () {
        // only one outstanding review () permitted
        return_if_fail (review_cancellable == null);

        review_cancellable = new Cancellable ();
        var result = yield do_review_cancellable ();
        review_cancellable = null;

        skip_review_for_live = false;
        return result;
    }

    private async bool do_review_cancellable () {
        return_if_fail (review_cancellable != null);

        nokvm_infobar.hide ();
        summary.clear ();

        if (source != null) {
            try {
                machine = new RemoteMachine (source);
            } catch (Boxes.Error error) {
                warning (error.message);
            }
        } else if (vm_creator != null && libvirt_machine == null) {
            try {
                machine = yield vm_creator.create_vm (review_cancellable);
            } catch (IOError.CANCELLED cancel_error) { // We did this, so ignore!
            } catch (GLib.Error error) {
                App.window.notificationbar.display_error (_("Box setup failed"));
                warning (error.message);
            }

            if (libvirt_machine == null) {
                // notify the VM creation failed
                notify_property ("machine");
                return false;
            }
        }

        if (review_cancellable.is_cancelled ())
            return false;

        review_label.set_text (_("Boxes will create a new box with the following properties:"));

        if (source != null) {
            var uri = Xml.URI.parse (source.uri);

            summary.add_property (_("Type"), source.source_type);

            if (uri != null && uri.server != null)
                summary.add_property (_("Host"), uri.server.down ());
            else
                summary.add_property (_("URI"), source.uri.down ());

            switch (uri.scheme) {
            case "spice":
                try {
                    int port = 0, tls_port = 0;

                    spice_validate_uri (source.uri, out port, out tls_port);
                    if (port > 0)
                        summary.add_property (_("Port"), port.to_string ());
                    if (tls_port > 0)
                        summary.add_property (_("TLS Port"), tls_port.to_string ());
                } catch (Boxes.Error error) {
                    // this shouldn't happen, since the URI was validated before
                    critical (error.message);
                }
                break;

            case "vnc":
                if (uri.port > 0)
                    summary.add_property (_("Port"), uri.port.to_string ());
                break;
            }

            if (App.app.has_broker_for_source_type (source.source_type)) {
                review_label.set_text (_("Will add boxes for all systems available from this account:"));
            }
        } else if (libvirt_machine != null) {
            foreach (var property in vm_creator.install_media.get_vm_properties ())
                summary.add_property (property.first, property.second);

            try {
                var config = null as GVirConfig.Domain;
                yield run_in_thread (() => {
                    config = libvirt_machine.domain.get_config (GVir.DomainXMLFlags.INACTIVE);
                });

                var memory = format_size (config.memory * Osinfo.KIBIBYTES, FormatSizeFlags.IEC_UNITS);
                summary.add_property (_("Memory"), memory);
            } catch (GLib.Error error) {
                warning ("Failed to get configuration for machine '%s': %s", libvirt_machine.name, error.message);
            }

            if (!libvirt_machine.importing && libvirt_machine.storage_volume != null) {
                try {
                    var volume_info = libvirt_machine.storage_volume.get_info ();
                    var capacity = format_size (volume_info.capacity);
                    summary.add_property (_("Disk"),  _("%s maximum".printf (capacity)));
                } catch (GLib.Error error) {
                    warning ("Failed to get information on volume '%s': %s",
                             libvirt_machine.storage_volume.get_name (),
                             error.message);
                }
            }

            nokvm_infobar.visible = (libvirt_machine.domain_config.get_virt_type () != GVirConfig.DomainVirtType.KVM);
        } else if (this.wizard_source.libvirt_sys_import) {
            review_label.set_text (this.wizard_source.libvirt_sys_importer.wizard_review_label);
        }

        if (machine != null)
            summary.append_customize_button (() => {
                // Selecting an item in UIState.WIZARD implies changing state to UIState.PROPERTIES
                App.app.select_item (machine);
            });

        return true;
    }

    private bool skip_review_for_live;

    private bool skip_page (Boxes.WizardPage page) {
        var forwards = page > this.page;
        var skip_to = page;

        // remote-display case
        if (source != null &&
            Boxes.WizardPage.SOURCE < page < Boxes.WizardPage.REVIEW)
            skip_to = forwards ? page + 1 : page - 1;

        // always skip preparation step backwards
        if (!forwards &&
            page == Boxes.WizardPage.PREPARATION)
            skip_to = page - 1;

        if (vm_creator != null) {
            // Skip SETUP page if installer media doesn't need it
            if (page == Boxes.WizardPage.SETUP &&
                !vm_creator.install_media.need_user_input_for_vm_creation)
                    skip_to = forwards ? page + 1 : page - 1;

            // Skip review for live media if told to do so
            if (page == Boxes.WizardPage.REVIEW && forwards
                && vm_creator.install_media.live
                && skip_review_for_live)
                    skip_to += 1;
        } else if (wizard_source.libvirt_sys_import) {
            if (page == Boxes.WizardPage.PREPARATION)
                skip_to = forwards ? page + 2 : page - 1;
            else if (page == Boxes.WizardPage.SETUP)
                skip_to = forwards ? page + 1 : page - 2;
        }

        if (skip_to != page) {
            this.page = skip_to;
            return true;
        }

        return false;
    }

    public void setup_ui () {
        cancel_button = App.window.topbar.wizard_cancel_btn;
        cancel_button.clicked.connect (() => {
            cleanup ();
            wizard_source.page = SourcePage.MAIN;
            App.app.set_state (UIState.COLLECTION);
        });
        back_button = App.window.topbar.wizard_back_btn;
        back_button.clicked.connect (() => {
            page = page - 1;
        });
        continue_button = App.window.topbar.wizard_continue_btn;
        continue_button.clicked.connect (() => {
            page = page + 1;
        });
        create_button = App.window.topbar.wizard_create_btn;
        create_button.clicked.connect (() => {
            create.begin ((obj, result) => {
            if (create.end (result))
                App.app.set_state (UIState.COLLECTION);
            else
                App.window.notificationbar.display_error (_("Box creation failed"));
            });
        });
    }

    public void open_with_uri (string uri, bool skip_review_for_live = true) {
        App.app.set_state (UIState.WIZARD);
        this.skip_review_for_live = skip_review_for_live;

        page = WizardPage.SOURCE;
        wizard_source.page = SourcePage.URL;
        wizard_source.uri = uri;
        page = WizardPage.PREPARATION;
    }

    private void ui_state_changed () {
        if (ui_state == UIState.WIZARD) {
            if (previous_ui_state == UIState.PROPERTIES)
                review.begin ();
            else {
                wizard_source.uri = "";
                wizard_source.libvirt_sys_import = false;
                page = WizardPage.INTRODUCTION;
            }
        }
    }

    private void destroy_machine () {
        if (review_cancellable != null)
            review_cancellable.cancel ();

        if (machine != null) {
            App.app.delete_machine (machine);
            machine = null;
        }
    }
}

[GtkTemplate (ui = "/org/gnome/Boxes/ui/wizard-summary.ui")]
private class Boxes.WizardSummary: Gtk.Grid {
    public delegate void CustomizeFunc ();

    private int current_row;

    construct {
        current_row = 0;
    }

    public void add_property (string name, string? value) {
        if (value == null)
            return;

        var label_name = new Gtk.Label (name);
        label_name.get_style_context ().add_class ("boxes-wizard-summary-prop-name-label");
        label_name.xalign = 1.0f;
        attach (label_name, 0, current_row, 1, 1);

        var label_value = new Gtk.Label (value);
        label_value.get_style_context ().add_class ("boxes-wizard-summary-prop-value-label");
        label_value.set_ellipsize (Pango.EllipsizeMode.END);
        label_value.set_max_width_chars (32);
        label_value.xalign = 0.0f;
        attach (label_value, 1, current_row, 1, 1);

        current_row += 1;
        show_all ();
    }

    public void append_customize_button (CustomizeFunc customize_func) {
        // there is nothing to customize if review page is empty
        if (current_row == 0)
            return;

        var button = new Gtk.Button.with_mnemonic (_("C_ustomize..."));
        button.get_style_context ().add_class ("boxes-wizard-summary-customize-button");
        attach (button, 2, current_row - 1, 1, 1);
        button.show ();

        button.clicked.connect (() => { customize_func (); });
    }

    public void clear () {
        foreach (var child in get_children ()) {
            remove (child);
        }

        current_row = 0;
    }
}
