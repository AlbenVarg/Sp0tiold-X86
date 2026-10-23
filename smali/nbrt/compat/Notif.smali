.class public final Lnbrt/compat/Notif;
.super Ljava/lang/Object;
.source "Notif.smali"


# direct methods
.method public constructor <init>()V
    .registers 1

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

# En API < 26 no existen canales de notificacion: devolvemos un objeto no nulo
# tipado como NotificationChannel para que la app omita la rama que lo crearia.
.method public static getChannel(Landroid/app/NotificationManager;Ljava/lang/String;)Landroid/app/NotificationChannel;
    .registers 3

    new-instance v0, Ljava/lang/Object;

    invoke-direct {v0}, Ljava/lang/Object;-><init>()V

    return-object v0
.end method

# no-op: no hay canales que crear en API < 26
.method public static createChannel(Landroid/app/NotificationManager;Ljava/lang/Object;)V
    .registers 2

    return-void
.end method

# no-op generico (p.ej. Vibrator.vibrate(VibrationEffect))
.method public static noop2(Ljava/lang/Object;Ljava/lang/Object;)V
    .registers 2

    return-void
.end method

# null tipado como VibrationEffect (API 26+)
.method public static nullVibration(Ljava/lang/Object;)Landroid/os/VibrationEffect;
    .registers 1

    const/4 v0, 0x0

    return-object v0
.end method

.method public static nullVibration2(JI)Landroid/os/VibrationEffect;
    .registers 4

    const/4 v0, 0x0

    return-object v0
.end method
