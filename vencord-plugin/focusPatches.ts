import type { Patch } from "@utils/types";

export const focusPatches: Omit<Patch, "plugin">[] = [
    {
        find: "ensureAudio(){",
        group: true,
        replacement: [
            {
                match: /(?<=constructor\([^)]*\)\{)(?=this\.name=)/,
                replace: "this.vcBridgeSoundKey=arguments[1];"
            },
            {
                match: /(play|loop)\(\)\{/g,
                replace: "$&if($self.focus.shouldSilenceSound(this))return;"
            },
            {
                match: /playWithListener\(\)\{/,
                replace: "$&if($self.focus.shouldSilenceSound(this))return Promise.resolve(false);"
            },
            {
                match: /(new Promise\(\((\i),\i\)=>\{this\.ensureAudio\(\)\.then\(\i=>\{)(?=\(null==\i\.duration)/,
                replace: "$1if($self.focus.shouldSilenceSound(this))return $2(false);"
            },
            {
                match: /destroyAudio\(\)\{/,
                replace: "$&$self.focus.forgetSound(this);"
            },
            {
                match: /\.then\((\i)=>\{\1\.loop=/g,
                replace: ".then($1=>{if($self.focus.shouldSilenceSound(this))return;$1.loop="
            },
            {
                match: /\i:function\(\i,\i\)\{(?=let \i=new Audio)/,
                replace: "$&if($self.focus.isActive())return;"
            }
        ]
    },
    {
        find: '"NotificationUtils"',
        group: true,
        replacement: [
            {
                match: /showNotification:async function\([^)]*\)\{/,
                replace: "$&if($self.focus.isActive())return;"
            },
            {
                match: /async function \i\(\i\)\{(?=let \i=arguments\.length>1)/,
                replace: "$&if($self.focus.isActive())return;"
            }
        ]
    },
    {
        find: "currentToastMap:new Map",
        replacement: {
            match: /\i:function\((\i)\)\{(?=let \i=\1\?\.surface)/,
            replace: "$&if($self.focus.isActive())return;"
        }
    },
    {
        find: "_handleSoundboardSoundReceived=",
        replacement: {
            match: /_handleSoundboardSound(?:Received|PlayLocally)=\i=>\{/g,
            replace: "$&$self.focus.trackSoundboard(this);if($self.focus.isActive())return;"
        }
    }
];
