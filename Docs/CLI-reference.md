# CLI command reference

<!-- Generated from ControlContract. Run Scripts/verify.swift --generate-docs. -->

The CLI reads and configures trackpad bindings, actions, application groups, and detection tuning through config.get, config.validate, and config.apply. Gesture Gym and live contacts are available in the app UI.

Input and successful result schemas below describe the supported protocol subset; configuration semantic checks also run on the server. Examples containing IDs or revisions require values from the current app. Configuration examples show shape only and are replacements, not merges: obtain config.get, edit its complete configuration while retaining unrelated fields, and validate before applying. Never apply a configuration example as a patch.

## schema

Read the complete command and configuration contract.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : true,
  "properties" : {
    "$defs" : {
      "additionalProperties" : true,
      "properties" : {

      },
      "required" : [

      ],
      "type" : "object"
    },
    "commands" : {
      "additionalProperties" : true,
      "properties" : {

      },
      "required" : [

      ],
      "type" : "object"
    },
    "protocolVersion" : {
      "type" : "integer"
    },
    "results" : {
      "additionalProperties" : true,
      "properties" : {

      },
      "required" : [

      ],
      "type" : "object"
    }
  },
  "required" : [
    "protocolVersion",
    "commands",
    "$defs",
    "results"
  ],
  "type" : "object"
}
```

## status

Read runtime status, module flags, revision, and current activity.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : true,
  "properties" : {
    "accessibility" : {
      "type" : "boolean"
    },
    "automation" : {
      "oneOf" : [
        {
          "$ref" : "#/$defs/WorkflowProgress"
        },
        {
          "type" : "null"
        }
      ]
    },
    "coffee" : {
      "$ref" : "#/$defs/CoffeeStatus"
    },
    "controlAvailable" : {
      "type" : "boolean"
    },
    "display" : {
      "$ref" : "#/$defs/DisplayStatus"
    },
    "inputError" : {
      "oneOf" : [
        {
          "type" : "string"
        },
        {
          "type" : "null"
        }
      ]
    },
    "login" : {
      "$ref" : "#/$defs/LoginStatus"
    },
    "modules" : {
      "additionalProperties" : false,
      "properties" : {
        "coffee" : {
          "type" : "boolean"
        },
        "display" : {
          "type" : "boolean"
        },
        "power" : {
          "type" : "boolean"
        },
        "snapping" : {
          "type" : "boolean"
        },
        "trackpad" : {
          "type" : "boolean"
        },
        "windows" : {
          "type" : "boolean"
        }
      },
      "required" : [
        "trackpad",
        "windows",
        "snapping",
        "display",
        "coffee",
        "power"
      ],
      "type" : "object"
    },
    "power" : {
      "$ref" : "#/$defs/PowerStatus"
    },
    "revision" : {
      "type" : "string"
    },
    "snapping" : {
      "$ref" : "#/$defs/SnappingStatus"
    },
    "switcher" : {
      "$ref" : "#/$defs/SwitcherStatus"
    },
    "trackpadRunning" : {
      "type" : "boolean"
    },
    "version" : {
      "type" : "string"
    }
  },
  "required" : [
    "version",
    "modules",
    "revision",
    "display",
    "coffee",
    "power",
    "automation"
  ],
  "type" : "object"
}
```

## login.status

Read macOS start-at-login registration and approval status.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/LoginStatus"
}
```

## login.set

Enable or disable start at login using macOS. Approval may still be required in Login Items settings.

Example parameters:

```json
{
  "enabled" : true
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "enabled" : {
      "type" : "boolean"
    }
  },
  "required" : [
    "enabled"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/LoginStatus"
}
```

## power.status

Read built-in battery charge and power state. Unknown readings are null; this does not control charging.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/PowerStatus"
}
```

## coffee.status

Read Coffee requested and effective power settings.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/CoffeeStatus"
}
```

## coffee.set

Set one or both Coffee power settings.

Example parameters:

```json
{
  "preventIdleSleep" : true
}
```

Input:

```json
{
  "additionalProperties" : false,
  "minProperties" : 1,
  "properties" : {
    "keepDisplayAwake" : {
      "type" : "boolean"
    },
    "preventIdleSleep" : {
      "type" : "boolean"
    }
  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/CoffeeStatus"
}
```

## config.get

Read the complete configuration and its revision.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "configuration" : {
      "additionalProperties" : true,
      "properties" : {

      },
      "required" : [

      ],
      "type" : "object"
    },
    "revision" : {
      "type" : "string"
    }
  },
  "required" : [
    "configuration",
    "revision"
  ],
  "type" : "object"
}
```

## automations.list

List saved automations.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {

  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "items" : {
    "$ref" : "#/$defs/Automation"
  },
  "type" : "array"
}
```

## config.validate

Validate a configuration without saving it; errors are returned in a successful report.

Example parameters:

```json
{
  "configuration" : {
    "bindings" : [

    ],
    "trackpadModuleEnabled" : false,
    "version" : 6
  }
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "configuration" : {
      "$ref" : "#/$defs/AppConfiguration"
    }
  },
  "required" : [
    "configuration"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "errors" : {
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    },
    "warnings" : {
      "items" : {
        "type" : "string"
      },
      "type" : "array"
    }
  },
  "required" : [
    "errors",
    "warnings"
  ],
  "type" : "object"
}
```

## config.apply

Apply a valid complete configuration if expectedRevision matches.

Example parameters:

```json
{
  "configuration" : {
    "bindings" : [

    ],
    "trackpadModuleEnabled" : false,
    "version" : 6
  },
  "expectedRevision" : "REVISION"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "configuration" : {
      "$ref" : "#/$defs/AppConfiguration"
    },
    "expectedRevision" : {
      "maxLength" : 64,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "configuration",
    "expectedRevision"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "revision" : {
      "type" : "string"
    }
  },
  "required" : [
    "revision"
  ],
  "type" : "object"
}
```

## config.undo

Undo the last apply if its revision still matches.

Example parameters:

```json
{
  "expectedRevision" : "REVISION"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "expectedRevision" : {
      "maxLength" : 64,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "expectedRevision"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "revision" : {
      "type" : "string"
    }
  },
  "required" : [
    "revision"
  ],
  "type" : "object"
}
```

## display.text

Display brief text.

Example parameters:

```json
{
  "text" : "Ready"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "duration" : {
      "default" : 0.5,
      "maximum" : 5,
      "minimum" : 0.2,
      "type" : "number"
    },
    "text" : {
      "maxLength" : 280,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "text"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "displayed" : {
      "type" : "boolean"
    }
  },
  "required" : [
    "displayed"
  ],
  "type" : "object"
}
```

## display.toast

Display a toast.

Example parameters:

```json
{
  "text" : "Ready"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "duration" : {
      "default" : 0.5,
      "maximum" : 5,
      "minimum" : 0.2,
      "type" : "number"
    },
    "text" : {
      "maxLength" : 280,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "text"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "displayed" : {
      "type" : "boolean"
    }
  },
  "required" : [
    "displayed"
  ],
  "type" : "object"
}
```

## display.progress.begin

Begin progress with named steps.

Example parameters:

```json
{
  "steps" : [
    "Open document",
    "Arrange windows"
  ],
  "title" : "Prepare review"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "steps" : {
      "items" : {
        "maxLength" : 120,
        "minLength" : 1,
        "type" : "string"
      },
      "maxItems" : 32,
      "minItems" : 1,
      "type" : "array"
    },
    "title" : {
      "maxLength" : 120,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "title",
    "steps"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "displayed" : {
      "type" : "boolean"
    },
    "id" : {
      "format" : "uuid",
      "type" : "string"
    }
  },
  "required" : [
    "id",
    "displayed"
  ],
  "type" : "object"
}
```

## display.progress.update

Update a progress step using a 1-based index.

Example parameters:

```json
{
  "id" : "00000000-0000-0000-0000-000000000001",
  "state" : "running",
  "step" : 1
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "format" : "uuid",
      "type" : "string"
    },
    "message" : {
      "maxLength" : 280,
      "minLength" : 1,
      "type" : "string"
    },
    "state" : {
      "enum" : [
        "pending",
        "running",
        "completed",
        "failed"
      ],
      "type" : "string"
    },
    "step" : {
      "maximum" : 32,
      "minimum" : 1,
      "type" : "integer"
    }
  },
  "required" : [
    "id",
    "step",
    "state"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "displayed" : {
      "type" : "boolean"
    }
  },
  "required" : [
    "displayed"
  ],
  "type" : "object"
}
```

## display.progress.finish

Complete or fail progress.

Example parameters:

```json
{
  "id" : "00000000-0000-0000-0000-000000000001"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "failed" : {
      "type" : "boolean"
    },
    "id" : {
      "format" : "uuid",
      "type" : "string"
    },
    "message" : {
      "maxLength" : 280,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "displayed" : {
      "type" : "boolean"
    }
  },
  "required" : [
    "displayed"
  ],
  "type" : "object"
}
```

## display.dismiss

Dismiss one progress session, or all sessions.

Example parameters:

```json
{

}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "format" : "uuid",
      "type" : "string"
    }
  },
  "required" : [

  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "dismissed" : {
      "type" : "boolean"
    }
  },
  "required" : [
    "dismissed"
  ],
  "type" : "object"
}
```

## automations.run

Run one saved automation by UUID or unique name.

Example parameters:

```json
{
  "automation" : "Prepare review"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "automation" : {
      "maxLength" : 120,
      "minLength" : 1,
      "type" : "string"
    }
  },
  "required" : [
    "automation"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "runID" : {
      "format" : "uuid",
      "type" : "string"
    },
    "state" : {
      "enum" : [
        "pending",
        "running",
        "completed",
        "failed",
        "cancelling",
        "cancelled"
      ],
      "type" : "string"
    }
  },
  "required" : [
    "runID",
    "state"
  ],
  "type" : "object"
}
```

## automations.status

Read recent automation run progress.

Example parameters:

```json
{
  "id" : "00000000-0000-0000-0000-000000000001"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "format" : "uuid",
      "type" : "string"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/WorkflowProgress"
}
```

## automations.cancel

Cancel an automation run.

Example parameters:

```json
{
  "id" : "00000000-0000-0000-0000-000000000001"
}
```

Input:

```json
{
  "additionalProperties" : false,
  "properties" : {
    "id" : {
      "format" : "uuid",
      "type" : "string"
    }
  },
  "required" : [
    "id"
  ],
  "type" : "object"
}
```

Successful result:

```json
{
  "$ref" : "#/$defs/WorkflowProgress"
}
```

## Shared definitions

```json
{
  "Action" : {
    "additionalProperties" : false,
    "properties" : {
      "applicationBundleIdentifier" : {
        "maxLength" : 255,
        "type" : "string"
      },
      "automationID" : {
        "format" : "uuid",
        "type" : "string"
      },
      "kind" : {
        "enum" : [
          "shortcut",
          "system",
          "appleScript",
          "showText",
          "automation",
          "openApplication"
        ],
        "type" : "string"
      },
      "script" : {
        "maxLength" : 65536,
        "type" : "string"
      },
      "shortcut" : {
        "$ref" : "#/$defs/Shortcut"
      },
      "system" : {
        "description" : "previousTab and nextTab are legacy input aliases, normalized to shortcut actions using Control–Shift–Tab and Control–Tab. Current System choices exclude these aliases; canonical output uses middleClick for their inactive system field.",
        "enum" : [
          "previousTab",
          "nextTab",
          "middleClick",
          "missionControl",
          "showDesktop",
          "spotlight",
          "playPause",
          "mute",
          "volumeDown",
          "volumeUp",
          "nextWindow",
          "previousWindow",
          "showWindowSwitcher"
        ],
        "type" : "string"
      },
      "text" : {
        "maxLength" : 280,
        "type" : "string"
      },
      "textDuration" : {
        "maximum" : 5,
        "minimum" : 0.2,
        "type" : "number"
      }
    },
    "required" : [
      "kind",
      "system",
      "script"
    ],
    "type" : "object"
  },
  "AppConfiguration" : {
    "additionalProperties" : false,
    "properties" : {
      "applicationGroups" : {
        "items" : {
          "$ref" : "#/$defs/ApplicationGroup"
        },
        "type" : "array"
      },
      "automations" : {
        "items" : {
          "$ref" : "#/$defs/Automation"
        },
        "type" : "array"
      },
      "bindings" : {
        "items" : {
          "$ref" : "#/$defs/Binding"
        },
        "type" : "array"
      },
      "coffeeModuleEnabled" : {
        "type" : "boolean"
      },
      "displayModuleEnabled" : {
        "type" : "boolean"
      },
      "hapticPattern" : {
        "$ref" : "#/$defs/Haptic"
      },
      "hapticsInPractice" : {
        "type" : "boolean"
      },
      "mouseTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "powerModuleEnabled" : {
        "type" : "boolean"
      },
      "snappingModuleEnabled" : {
        "type" : "boolean"
      },
      "stacks" : {
        "items" : {
          "$ref" : "#/$defs/GestureStack"
        },
        "type" : "array"
      },
      "trackpadModuleEnabled" : {
        "type" : "boolean"
      },
      "trackpadTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "version" : {
        "enum" : [
          6
        ],
        "type" : "integer"
      },
      "visualFeedbackEnabled" : {
        "type" : "boolean"
      },
      "windowSwitcher" : {
        "$ref" : "#/$defs/WindowSwitcher"
      }
    },
    "required" : [
      "version",
      "bindings"
    ],
    "type" : "object"
  },
  "ApplicationGroup" : {
    "additionalProperties" : false,
    "properties" : {
      "applications" : {
        "items" : {
          "additionalProperties" : false,
          "properties" : {
            "bundleIdentifier" : {
              "maxLength" : 255,
              "minLength" : 1,
              "type" : "string"
            },
            "name" : {
              "maxLength" : 120,
              "minLength" : 1,
              "type" : "string"
            }
          },
          "required" : [
            "name",
            "bundleIdentifier"
          ],
          "type" : "object"
        },
        "type" : "array"
      },
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "name" : {
        "maxLength" : 120,
        "minLength" : 1,
        "type" : "string"
      }
    },
    "required" : [
      "id",
      "name",
      "applications"
    ],
    "type" : "object"
  },
  "Automation" : {
    "additionalProperties" : false,
    "properties" : {
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "name" : {
        "maxLength" : 120,
        "minLength" : 1,
        "type" : "string"
      },
      "steps" : {
        "items" : {
          "$ref" : "#/$defs/AutomationStep"
        },
        "maxItems" : 32,
        "minItems" : 1,
        "type" : "array"
      }
    },
    "required" : [
      "id",
      "name",
      "steps"
    ],
    "type" : "object"
  },
  "AutomationStep" : {
    "additionalProperties" : false,
    "description" : "Exactly one action or delay. Actions may not have kind automation.",
    "oneOf" : [
      {
        "not" : {
          "required" : [
            "delay"
          ]
        },
        "required" : [
          "action"
        ]
      },
      {
        "not" : {
          "required" : [
            "action"
          ]
        },
        "required" : [
          "delay"
        ]
      }
    ],
    "properties" : {
      "action" : {
        "$ref" : "#/$defs/Action"
      },
      "delay" : {
        "maximum" : 30,
        "minimum" : 0,
        "type" : "number"
      },
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "name" : {
        "maxLength" : 120,
        "minLength" : 1,
        "type" : "string"
      }
    },
    "required" : [
      "id",
      "name"
    ],
    "type" : "object"
  },
  "Binding" : {
    "additionalProperties" : false,
    "properties" : {
      "action" : {
        "$ref" : "#/$defs/Action"
      },
      "applicationGroupID" : {
        "format" : "uuid",
        "type" : "string"
      },
      "device" : {
        "enum" : [
          "trackpad",
          "magicMouse"
        ],
        "type" : "string"
      },
      "gesture" : {
        "$ref" : "#/$defs/Gesture"
      },
      "hapticPattern" : {
        "$ref" : "#/$defs/Haptic"
      },
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "isEnabled" : {
        "type" : "boolean"
      },
      "keyboardModifiers" : {
        "$ref" : "#/$defs/KeyboardModifierRequirement"
      },
      "showsToast" : {
        "default" : true,
        "description" : "Allow this binding to show gesture toasts when global gesture toasts and Overlays are enabled. Show Text actions use their own message.",
        "type" : "boolean"
      }
    },
    "required" : [
      "id",
      "device",
      "gesture",
      "action",
      "isEnabled"
    ],
    "type" : "object"
  },
  "CoffeeStatus" : {
    "additionalProperties" : false,
    "properties" : {
      "effective" : {
        "additionalProperties" : false,
        "properties" : {
          "keepDisplayAwake" : {
            "type" : "boolean"
          },
          "preventIdleSleep" : {
            "type" : "boolean"
          }
        },
        "required" : [
          "preventIdleSleep",
          "keepDisplayAwake"
        ],
        "type" : "object"
      },
      "enabled" : {
        "type" : "boolean"
      },
      "error" : {
        "oneOf" : [
          {
            "type" : "string"
          },
          {
            "type" : "null"
          }
        ]
      },
      "isActive" : {
        "type" : "boolean"
      },
      "requested" : {
        "additionalProperties" : false,
        "properties" : {
          "keepDisplayAwake" : {
            "type" : "boolean"
          },
          "preventIdleSleep" : {
            "type" : "boolean"
          }
        },
        "required" : [
          "preventIdleSleep",
          "keepDisplayAwake"
        ],
        "type" : "object"
      },
      "running" : {
        "type" : "boolean"
      }
    },
    "required" : [
      "enabled",
      "running",
      "isActive",
      "requested",
      "effective",
      "error"
    ],
    "type" : "object"
  },
  "DisplayStatus" : {
    "additionalProperties" : false,
    "properties" : {
      "available" : {
        "type" : "boolean"
      },
      "enabled" : {
        "type" : "boolean"
      },
      "sessions" : {
        "items" : {
          "$ref" : "#/$defs/WorkflowProgress"
        },
        "type" : "array"
      }
    },
    "required" : [
      "available",
      "enabled",
      "sessions"
    ],
    "type" : "object"
  },
  "Gesture" : {
    "additionalProperties" : false,
    "properties" : {
      "corner" : {
        "enum" : [
          "none",
          "topLeft",
          "topRight",
          "bottomLeft",
          "bottomRight"
        ],
        "type" : "string"
      },
      "fingers" : {
        "maximum" : 5,
        "minimum" : 1,
        "type" : "integer"
      },
      "kind" : {
        "enum" : [
          "tap",
          "longTouch",
          "doubleTap",
          "click",
          "forceClick",
          "tipTapLeft",
          "tipTapRight",
          "tipTapMiddle",
          "doubleTipTapLeft",
          "doubleTipTapRight",
          "doubleTipTapMiddle",
          "tipSwipeLeft",
          "tipSwipeRight",
          "tipSwipeUp",
          "tipSwipeDown",
          "swipeLeft",
          "swipeRight",
          "swipeUp",
          "swipeDown"
        ],
        "type" : "string"
      }
    },
    "required" : [
      "kind",
      "fingers",
      "corner"
    ],
    "type" : "object"
  },
  "GestureStack" : {
    "additionalProperties" : false,
    "properties" : {
      "applicationGroupID" : {
        "format" : "uuid",
        "type" : "string"
      },
      "bindings" : {
        "items" : {
          "$ref" : "#/$defs/GestureStackBinding"
        },
        "maxItems" : 32,
        "type" : "array"
      },
      "corner" : {
        "enum" : [
          "none",
          "topLeft",
          "topRight",
          "bottomLeft",
          "bottomRight"
        ],
        "type" : "string"
      },
      "device" : {
        "enum" : [
          "trackpad",
          "magicMouse"
        ],
        "type" : "string"
      },
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "isEnabled" : {
        "type" : "boolean"
      },
      "keyboardModifiers" : {
        "$ref" : "#/$defs/KeyboardModifierRequirement"
      },
      "name" : {
        "maxLength" : 120,
        "type" : "string"
      },
      "releaseActions" : {
        "items" : {
          "$ref" : "#/$defs/Action"
        },
        "maxItems" : 32,
        "type" : "array"
      },
      "startActions" : {
        "items" : {
          "$ref" : "#/$defs/GestureStackAction"
        },
        "maxItems" : 32,
        "type" : "array"
      }
    },
    "required" : [
      "id",
      "name",
      "device",
      "corner",
      "startActions",
      "bindings",
      "releaseActions"
    ],
    "type" : "object"
  },
  "GestureStackAction" : {
    "additionalProperties" : false,
    "properties" : {
      "action" : {
        "$ref" : "#/$defs/Action"
      },
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "kind" : {
        "enum" : [
          "action",
          "holdModifiers"
        ],
        "type" : "string"
      },
      "modifiers" : {
        "items" : {
          "enum" : [
            "control",
            "command",
            "option",
            "shift"
          ],
          "type" : "string"
        },
        "maxItems" : 4,
        "type" : "array"
      }
    },
    "required" : [
      "id",
      "kind",
      "action",
      "modifiers"
    ],
    "type" : "object"
  },
  "GestureStackBinding" : {
    "additionalProperties" : false,
    "properties" : {
      "actions" : {
        "items" : {
          "$ref" : "#/$defs/Action"
        },
        "maxItems" : 32,
        "type" : "array"
      },
      "gesture" : {
        "$ref" : "#/$defs/Gesture"
      },
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "isEnabled" : {
        "type" : "boolean"
      },
      "keyboardModifiers" : {
        "$ref" : "#/$defs/KeyboardModifierRequirement"
      }
    },
    "required" : [
      "id",
      "gesture",
      "actions"
    ],
    "type" : "object"
  },
  "Haptic" : {
    "enum" : [
      "off",
      "light",
      "click",
      "firm",
      "doubleClick",
      "strongDouble"
    ],
    "type" : "string"
  },
  "KeyboardModifierRequirement" : {
    "additionalProperties" : false,
    "properties" : {
      "mode" : {
        "enum" : [
          "any",
          "exact"
        ],
        "type" : "string"
      },
      "modifiers" : {
        "items" : {
          "enum" : [
            "control",
            "command",
            "option",
            "shift"
          ],
          "type" : "string"
        },
        "maxItems" : 4,
        "type" : "array"
      }
    },
    "required" : [
      "mode",
      "modifiers"
    ],
    "type" : "object"
  },
  "LegacyAppConfiguration" : {
    "additionalProperties" : false,
    "properties" : {
      "applicationGroups" : {
        "items" : {
          "$ref" : "#/$defs/ApplicationGroup"
        },
        "type" : "array"
      },
      "automations" : {
        "items" : {
          "$ref" : "#/$defs/Automation"
        },
        "type" : "array"
      },
      "bindings" : {
        "items" : {
          "$ref" : "#/$defs/Binding"
        },
        "type" : "array"
      },
      "coffeeModuleEnabled" : {
        "type" : "boolean"
      },
      "displayModuleEnabled" : {
        "type" : "boolean"
      },
      "hapticPattern" : {
        "$ref" : "#/$defs/Haptic"
      },
      "hapticsInPractice" : {
        "type" : "boolean"
      },
      "isEnabled" : {
        "type" : "boolean"
      },
      "mouseTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "pauseAll" : {
        "type" : "boolean"
      },
      "snappingModuleEnabled" : {
        "type" : "boolean"
      },
      "trackpadModuleEnabled" : {
        "type" : "boolean"
      },
      "trackpadTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "version" : {
        "enum" : [
          1,
          2,
          3
        ],
        "type" : "integer"
      },
      "visualFeedbackEnabled" : {
        "type" : "boolean"
      },
      "windowSwitcher" : {
        "$ref" : "#/$defs/WindowSwitcher"
      }
    },
    "required" : [
      "version",
      "bindings",
      "isEnabled"
    ],
    "type" : "object"
  },
  "LoginStatus" : {
    "additionalProperties" : false,
    "properties" : {
      "enabled" : {
        "type" : "boolean"
      },
      "error" : {
        "oneOf" : [
          {
            "type" : "string"
          },
          {
            "type" : "null"
          }
        ]
      },
      "status" : {
        "enum" : [
          "notRegistered",
          "enabled",
          "requiresApproval",
          "notFound"
        ],
        "type" : "string"
      }
    },
    "required" : [
      "status",
      "enabled",
      "error"
    ],
    "type" : "object"
  },
  "PowerStatus" : {
    "additionalProperties" : false,
    "properties" : {
      "adapterName" : {
        "oneOf" : [
          {
            "type" : "string"
          },
          {
            "type" : "null"
          }
        ]
      },
      "adapterWatts" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "batteryPresent" : {
        "oneOf" : [
          {
            "type" : "boolean"
          },
          {
            "type" : "null"
          }
        ]
      },
      "batteryWatts" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "chargePercent" : {
        "oneOf" : [
          {
            "maximum" : 100,
            "minimum" : 0,
            "type" : "integer"
          },
          {
            "type" : "null"
          }
        ]
      },
      "cycleCount" : {
        "oneOf" : [
          {
            "type" : "integer"
          },
          {
            "type" : "null"
          }
        ]
      },
      "designCapacityMAh" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "enabled" : {
        "type" : "boolean"
      },
      "error" : {
        "oneOf" : [
          {
            "type" : "string"
          },
          {
            "type" : "null"
          }
        ]
      },
      "estimatedHealthPercent" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "estimatedMacWatts" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "externalConnected" : {
        "oneOf" : [
          {
            "type" : "boolean"
          },
          {
            "type" : "null"
          }
        ]
      },
      "fullChargeCapacityMAh" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "healthEstimateSource" : {
        "oneOf" : [
          {
            "enum" : [
              "nominalCapacity",
              "fullChargeCapacity"
            ],
            "type" : "string"
          },
          {
            "type" : "null"
          }
        ]
      },
      "inputWatts" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "isCharged" : {
        "oneOf" : [
          {
            "type" : "boolean"
          },
          {
            "type" : "null"
          }
        ]
      },
      "isCharging" : {
        "oneOf" : [
          {
            "type" : "boolean"
          },
          {
            "type" : "null"
          }
        ]
      },
      "nominalChargeCapacityMAh" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      },
      "powerSource" : {
        "oneOf" : [
          {
            "enum" : [
              "ac",
              "battery"
            ],
            "type" : "string"
          },
          {
            "type" : "null"
          }
        ]
      },
      "running" : {
        "type" : "boolean"
      },
      "systemLoadWatts" : {
        "oneOf" : [
          {
            "type" : "number"
          },
          {
            "type" : "null"
          }
        ]
      }
    },
    "required" : [
      "enabled",
      "running",
      "batteryPresent",
      "chargePercent",
      "isCharging",
      "isCharged",
      "powerSource",
      "error",
      "cycleCount",
      "designCapacityMAh",
      "fullChargeCapacityMAh",
      "nominalChargeCapacityMAh",
      "estimatedHealthPercent",
      "healthEstimateSource",
      "adapterWatts",
      "adapterName",
      "externalConnected",
      "batteryWatts",
      "inputWatts",
      "systemLoadWatts",
      "estimatedMacWatts"
    ],
    "type" : "object"
  },
  "Shortcut" : {
    "additionalProperties" : false,
    "properties" : {
      "keyCode" : {
        "maximum" : 65535,
        "minimum" : 0,
        "type" : "integer"
      },
      "keyLabel" : {
        "maxLength" : 120,
        "minLength" : 1,
        "type" : "string"
      },
      "modifiers" : {
        "minimum" : 0,
        "type" : "integer"
      }
    },
    "required" : [
      "keyCode",
      "modifiers",
      "keyLabel"
    ],
    "type" : "object"
  },
  "SnappingDiagnostics" : {
    "additionalProperties" : false,
    "properties" : {
      "completedDrags" : {
        "items" : {
          "$ref" : "#/$defs/SnappingInteraction"
        },
        "maxItems" : 8,
        "type" : "array"
      },
      "latestInteraction" : {
        "$ref" : "#/$defs/SnappingInteraction"
      },
      "totalMouseDownCount" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "totalMouseDragCount" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "totalMouseUpCount" : {
        "minimum" : 0,
        "type" : "integer"
      }
    },
    "required" : [
      "totalMouseDownCount",
      "totalMouseDragCount",
      "totalMouseUpCount",
      "latestInteraction",
      "completedDrags"
    ],
    "type" : "object"
  },
  "SnappingInteraction" : {
    "additionalProperties" : false,
    "properties" : {
      "axHitError" : {
        "type" : "integer"
      },
      "axResults" : {
        "additionalProperties" : false,
        "properties" : {
          "AXFullScreen" : {
            "type" : "integer"
          },
          "AXMinimized" : {
            "type" : "integer"
          },
          "AXPosition" : {
            "type" : "integer"
          },
          "AXRole" : {
            "type" : "integer"
          },
          "AXSize" : {
            "type" : "integer"
          },
          "AXSubrole" : {
            "type" : "integer"
          },
          "AXWindow" : {
            "type" : "integer"
          },
          "position_settable" : {
            "type" : "integer"
          },
          "set_position" : {
            "type" : "integer"
          },
          "set_size" : {
            "type" : "integer"
          },
          "size_settable" : {
            "type" : "integer"
          }
        },
        "required" : [

        ],
        "type" : "object"
      },
      "commitSucceeded" : {
        "type" : "boolean"
      },
      "completed" : {
        "type" : "boolean"
      },
      "eventHandlingWindowID" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "eventTargetPID" : {
        "type" : "integer"
      },
      "eventUnderPointerWindowID" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "firstContainingLayer" : {
        "type" : "integer"
      },
      "firstContainingPID" : {
        "type" : "integer"
      },
      "generation" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "mouseDownCount" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "mouseDragCount" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "mouseUpCount" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "movementConfirmed" : {
        "type" : "boolean"
      },
      "processedDragCount" : {
        "minimum" : 0,
        "type" : "integer"
      },
      "reason" : {
        "type" : "string"
      },
      "resolutionMethod" : {
        "type" : "string"
      },
      "resolved" : {
        "type" : "boolean"
      },
      "routingMethod" : {
        "type" : "string"
      },
      "selectedPID" : {
        "type" : "integer"
      },
      "stage" : {
        "type" : "string"
      },
      "targetFound" : {
        "type" : "boolean"
      }
    },
    "required" : [
      "generation",
      "stage",
      "mouseDownCount",
      "mouseDragCount",
      "mouseUpCount",
      "processedDragCount",
      "axResults",
      "resolved",
      "movementConfirmed",
      "targetFound",
      "completed"
    ],
    "type" : "object"
  },
  "SnappingStatus" : {
    "additionalProperties" : false,
    "properties" : {
      "diagnostics" : {
        "oneOf" : [
          {
            "$ref" : "#/$defs/SnappingDiagnostics"
          },
          {
            "type" : "null"
          }
        ]
      },
      "eligible" : {
        "type" : "boolean"
      },
      "enabled" : {
        "type" : "boolean"
      },
      "monitoring" : {
        "type" : "boolean"
      },
      "status" : {
        "type" : "string"
      }
    },
    "required" : [
      "enabled",
      "eligible",
      "monitoring",
      "status",
      "diagnostics"
    ],
    "type" : "object"
  },
  "SwitcherStatus" : {
    "additionalProperties" : false,
    "properties" : {
      "activationDiagnostics" : {
        "items" : {
          "type" : "string"
        },
        "maxItems" : 24,
        "type" : "array"
      },
      "keyboardAvailable" : {
        "type" : "boolean"
      },
      "loading" : {
        "type" : "boolean"
      },
      "showing" : {
        "type" : "boolean"
      }
    },
    "required" : [
      "showing",
      "loading",
      "keyboardAvailable",
      "activationDiagnostics"
    ],
    "type" : "object"
  },
  "Tuning" : {
    "additionalProperties" : false,
    "properties" : {
      "anchorHold" : {
        "maximum" : 0.5,
        "minimum" : 0.05,
        "type" : "number"
      },
      "cornerHold" : {
        "maximum" : 0.8,
        "minimum" : 0.1,
        "type" : "number"
      },
      "cornerSize" : {
        "maximum" : 0.35,
        "minimum" : 0.1,
        "type" : "number"
      },
      "doubleTapInterval" : {
        "maximum" : 0.6,
        "minimum" : 0.15,
        "type" : "number"
      },
      "handAngleDegrees" : {
        "maximum" : 60,
        "minimum" : -60,
        "type" : "number"
      },
      "longTouchDuration" : {
        "maximum" : 1.5,
        "minimum" : 0.3,
        "type" : "number"
      },
      "swipeTravel" : {
        "maximum" : 0.35,
        "minimum" : 0.05,
        "type" : "number"
      },
      "tapDuration" : {
        "maximum" : 0.8,
        "minimum" : 0.1,
        "type" : "number"
      },
      "tapTravel" : {
        "maximum" : 0.12,
        "minimum" : 0.01,
        "type" : "number"
      },
      "tipEdgeDeadzone" : {
        "maximum" : 0.15,
        "minimum" : 0,
        "type" : "number"
      },
      "tipMaxSeparation" : {
        "maximum" : 0.8,
        "minimum" : 0.15,
        "type" : "number"
      },
      "tipSeparation" : {
        "maximum" : 0.2,
        "minimum" : 0.02,
        "type" : "number"
      }
    },
    "required" : [
      "tapDuration",
      "tapTravel",
      "anchorHold",
      "cornerHold",
      "swipeTravel",
      "handAngleDegrees",
      "tipSeparation",
      "cornerSize"
    ],
    "type" : "object"
  },
  "Version4AppConfiguration" : {
    "additionalProperties" : false,
    "properties" : {
      "applicationGroups" : {
        "items" : {
          "$ref" : "#/$defs/ApplicationGroup"
        },
        "type" : "array"
      },
      "automations" : {
        "items" : {
          "$ref" : "#/$defs/Automation"
        },
        "type" : "array"
      },
      "bindings" : {
        "items" : {
          "$ref" : "#/$defs/Binding"
        },
        "type" : "array"
      },
      "coffeeModuleEnabled" : {
        "type" : "boolean"
      },
      "displayModuleEnabled" : {
        "type" : "boolean"
      },
      "hapticPattern" : {
        "$ref" : "#/$defs/Haptic"
      },
      "hapticsInPractice" : {
        "type" : "boolean"
      },
      "mouseTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "snappingModuleEnabled" : {
        "type" : "boolean"
      },
      "trackpadModuleEnabled" : {
        "type" : "boolean"
      },
      "trackpadTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "version" : {
        "enum" : [
          4
        ],
        "type" : "integer"
      },
      "visualFeedbackEnabled" : {
        "type" : "boolean"
      },
      "windowSwitcher" : {
        "$ref" : "#/$defs/WindowSwitcher"
      }
    },
    "required" : [
      "version",
      "bindings"
    ],
    "type" : "object"
  },
  "Version5AppConfiguration" : {
    "additionalProperties" : false,
    "properties" : {
      "applicationGroups" : {
        "items" : {
          "$ref" : "#/$defs/ApplicationGroup"
        },
        "type" : "array"
      },
      "automations" : {
        "items" : {
          "$ref" : "#/$defs/Automation"
        },
        "type" : "array"
      },
      "bindings" : {
        "items" : {
          "$ref" : "#/$defs/Binding"
        },
        "type" : "array"
      },
      "coffeeModuleEnabled" : {
        "type" : "boolean"
      },
      "displayModuleEnabled" : {
        "type" : "boolean"
      },
      "hapticPattern" : {
        "$ref" : "#/$defs/Haptic"
      },
      "hapticsInPractice" : {
        "type" : "boolean"
      },
      "mouseTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "snappingModuleEnabled" : {
        "type" : "boolean"
      },
      "stacks" : {
        "items" : {
          "$ref" : "#/$defs/GestureStack"
        },
        "type" : "array"
      },
      "trackpadModuleEnabled" : {
        "type" : "boolean"
      },
      "trackpadTuning" : {
        "$ref" : "#/$defs/Tuning"
      },
      "version" : {
        "enum" : [
          5
        ],
        "type" : "integer"
      },
      "visualFeedbackEnabled" : {
        "type" : "boolean"
      },
      "windowSwitcher" : {
        "$ref" : "#/$defs/WindowSwitcher"
      }
    },
    "required" : [
      "version",
      "bindings"
    ],
    "type" : "object"
  },
  "WindowSwitcher" : {
    "additionalProperties" : false,
    "properties" : {
      "currentAppOnly" : {
        "type" : "boolean"
      },
      "gridScale" : {
        "maximum" : 1.5,
        "minimum" : 0.75,
        "type" : "number"
      },
      "includeHidden" : {
        "type" : "boolean"
      },
      "includeMinimized" : {
        "type" : "boolean"
      },
      "isEnabled" : {
        "type" : "boolean"
      },
      "layout" : {
        "enum" : [
          "list",
          "grid"
        ],
        "type" : "string"
      },
      "previewScale" : {
        "maximum" : 1.5,
        "minimum" : 0.75,
        "type" : "number"
      },
      "shortcut" : {
        "enum" : [
          "optionTab",
          "commandTab",
          "controlOptionTab"
        ],
        "type" : "string"
      },
      "showsPreviews" : {
        "type" : "boolean"
      },
      "snappingEnabled" : {
        "description" : "Legacy import field. Used only when top-level snappingModuleEnabled is absent, and only if this Switcher was enabled. New configurations must use snappingModuleEnabled; exports omit this field.",
        "type" : "boolean"
      }
    },
    "required" : [
      "isEnabled",
      "shortcut",
      "currentAppOnly",
      "includeMinimized",
      "includeHidden"
    ],
    "type" : "object"
  },
  "WorkflowProgress" : {
    "additionalProperties" : false,
    "properties" : {
      "id" : {
        "format" : "uuid",
        "type" : "string"
      },
      "message" : {
        "type" : "string"
      },
      "state" : {
        "enum" : [
          "pending",
          "running",
          "completed",
          "failed",
          "cancelling",
          "cancelled"
        ],
        "type" : "string"
      },
      "steps" : {
        "items" : {
          "additionalProperties" : false,
          "properties" : {
            "message" : {
              "type" : "string"
            },
            "name" : {
              "type" : "string"
            },
            "state" : {
              "enum" : [
                "pending",
                "running",
                "completed",
                "failed",
                "cancelling",
                "cancelled"
              ],
              "type" : "string"
            }
          },
          "required" : [
            "name",
            "state"
          ],
          "type" : "object"
        },
        "type" : "array"
      },
      "title" : {
        "type" : "string"
      }
    },
    "required" : [
      "id",
      "title",
      "state",
      "steps"
    ],
    "type" : "object"
  }
}
```
