import { definePluginSettings } from "@api/Settings";
import { OptionType } from "@utils/types";

export default definePluginSettings({
    port: {
        type: OptionType.NUMBER,
        description: "Port of the local vc-bridge daemon (restart Vesktop after changing)",
        default: 6475,
        restartNeeded: true
    },
    debug: {
        type: OptionType.BOOLEAN,
        description: "Allow the local daemon to evaluate JS in the client (vcb eval). Only for debugging.",
        default: false
    },
    focusChannelIds: {
        type: OptionType.STRING,
        description: "Voice channels with Focus enabled (managed by the voice panel)",
        default: "",
        hidden: true
    }
});
