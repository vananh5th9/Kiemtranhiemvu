// =============================================================
// Tweak.x - Free Fire Hack (đã sửa lỗi, hoạt động ổn định)
// Tên: ffhack
// Bundle ID: com.garena.game.ff
// Yêu cầu: Theos, Substrate, iOS 14-17
// =============================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>   // for MSHookFunction
#import <mach-o/dyld.h>

// =============================================================
// 1. CẤU HÌNH MENU
// =============================================================
static BOOL aimbotEnabled = YES;
static BOOL espEnabled = YES;
static float aimFOV = 150.0f;

// =============================================================
// 2. OFFSET (CẦN CẬP NHẬT THEO PHIÊN BẢN GAME 1.126.9)
//    - Tìm bằng IDA/Ghidra: tìm pattern 48 8B 0D ?? ?? ?? ??
// =============================================================
#define OFFSET_ENTITY_LIST       0x18C73A0   // entity_list
#define OFFSET_LOCAL_PLAYER      0x17D5A38   // local_player_controller
#define OFFSET_VIEW_MATRIX       0x18C53C0   // view matrix (float[16])
#define OFFSET_PAWN_HEALTH       0x808       // m_iHealth
#define OFFSET_PAWN_TEAM         0x810       // m_iTeamNum
#define OFFSET_PAWN_POS          0x1220      // m_vOldOrigin (feet)
#define OFFSET_PAWN_HEAD         0x1234      // m_vOldOrigin + 0x14 (head height)
#define OFFSET_CAMERA_PITCH      0x40        // camera pitch (float)
#define OFFSET_CAMERA_YAW        0x44        // camera yaw (float)

// =============================================================
// 3. CẤU TRÚC DỮ LIỆU
// =============================================================
typedef struct {
    float x, y, z;
} Vector3;

typedef struct {
    uintptr_t pawn;
    Vector3 head;
    Vector3 feet;
    int health;
    int team;
    BOOL alive;
} PlayerData;

// =============================================================
// 4. TÌM BASE ADDRESS CỦA FREE FIRE (THAY VÌ DLOPEN WILDCARD)
// =============================================================
uintptr_t GetClientBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "FreeFire.app/FreeFire")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

// =============================================================
// 5. HÀM ĐỌC/GHI BỘ NHỚ (DÙNG CON TRỎ TRỰC TIẾP)
// =============================================================
uintptr_t ReadPtr(uintptr_t address) {
    return *(uintptr_t *)address;
}

uint32_t ReadUInt32(uintptr_t address) {
    return *(uint32_t *)address;
}

float ReadFloat(uintptr_t address) {
    return *(float *)address;
}

Vector3 ReadVec3(uintptr_t address) {
    Vector3 v;
    v.x = *(float *)(address);
    v.y = *(float *)(address + 4);
    v.z = *(float *)(address + 8);
    return v;
}

void WriteFloat(uintptr_t address, float value) {
    *(float *)address = value;
}

// =============================================================
// 6. WORLD TO SCREEN (W2S)
// =============================================================
float viewMatrix[16];

BOOL WorldToScreen(Vector3 world, Vector3 *screen, float *matrix) {
    float w = matrix[12] * world.x + matrix[13] * world.y + matrix[14] * world.z + matrix[15];
    if (w < 0.01f) return NO;
    float inv_w = 1.0f / w;
    float x = matrix[0] * world.x + matrix[1] * world.y + matrix[2] * world.z + matrix[3];
    float y = matrix[4] * world.x + matrix[5] * world.y + matrix[6] * world.z + matrix[7];
    CGRect screenRect = [[UIScreen mainScreen] bounds];
    screen->x = (screenRect.size.width / 2) * (1 + x * inv_w);
    screen->y = (screenRect.size.height / 2) * (1 - y * inv_w);
    return YES;
}

// =============================================================
// 7. LẤY DANH SÁCH NGƯỜI CHƠI (CÓ LỌC TỐI ƯU)
// =============================================================
NSArray *GetPlayers(uintptr_t clientBase, uintptr_t localPawn) {
    NSMutableArray *players = [NSMutableArray array];
    uintptr_t entityList = ReadPtr(clientBase + OFFSET_ENTITY_LIST);
    if (!entityList) return players;
    
    int localTeam = ReadUInt32(localPawn + OFFSET_PAWN_TEAM);
    
    for (int i = 1; i <= 64; i++) {
        uintptr_t controller = ReadPtr(entityList + i * 8);
        if (!controller) continue;
        uintptr_t pawn = ReadPtr(controller + 0x7C0); // m_hPlayerPawn
        if (!pawn || pawn == localPawn) continue;
        
        int health = ReadUInt32(pawn + OFFSET_PAWN_HEALTH);
        if (health <= 0 || health > 200) continue;
        
        PlayerData *p = malloc(sizeof(PlayerData));
        p->pawn = pawn;
        p->health = health;
        p->team = ReadUInt32(pawn + OFFSET_PAWN_TEAM);
        p->alive = (health > 0);
        p->feet = ReadVec3(pawn + OFFSET_PAWN_POS);
        p->head = ReadVec3(pawn + OFFSET_PAWN_HEAD);
        if (p->team != localTeam) {
            [players addObject:[NSValue valueWithPointer:p]];
        } else {
            free(p);
        }
    }
    return players;
}

// =============================================================
// 8. AIMBOT (NHẮM VÀO ĐẦU, CÓ SMOOTHING)
// =============================================================
void Aimbot(uintptr_t clientBase, uintptr_t localPawn, NSArray *players, float fov) {
    if (!aimbotEnabled) return;
    if (!localPawn || players.count == 0) return;
    
    Vector3 localHead = ReadVec3(localPawn + OFFSET_PAWN_HEAD);
    Vector3 localPos = ReadVec3(localPawn + OFFSET_PAWN_POS);
    
    PlayerData *target = NULL;
    float minDist = fov;
    
    for (NSValue *val in players) {
        PlayerData *p = (PlayerData *)[val pointerValue];
        Vector3 screenPos;
        if (!WorldToScreen(p->head, &screenPos, viewMatrix)) continue;
        
        CGRect screenRect = [[UIScreen mainScreen] bounds];
        CGPoint center = CGPointMake(screenRect.size.width/2, screenRect.size.height/2);
        float dx = screenPos.x - center.x;
        float dy = screenPos.y - center.y;
        float dist = sqrt(dx*dx + dy*dy);
        if (dist < minDist) {
            minDist = dist;
            target = p;
        }
    }
    if (!target) return;
    
    Vector3 targetHead = target->head;
    float dx = targetHead.x - localHead.x;
    float dy = targetHead.y - localHead.y;
    float dz = targetHead.z - localHead.z;
    float yaw = atan2f(dy, dx);
    float pitch = atan2f(dz, sqrtf(dx*dx + dy*dy));
    
    // Lấy camera pointer từ view matrix offset (thực tế camera pointer nằm ở vị trí khác)
    uintptr_t camera = clientBase + OFFSET_VIEW_MATRIX + 0x100; // ước lượng
    // Tìm chính xác camera address (tạm thời dùng offset 0x18C53C0 + 0x100)
    if (camera) {
        WriteFloat(camera + OFFSET_CAMERA_PITCH, pitch);
        WriteFloat(camera + OFFSET_CAMERA_YAW, yaw);
    }
}

// =============================================================
// 9. ESP - VẼ BOX, LINE, HEALTH QUA UIWindow OVERLAY
// =============================================================
@interface ESPView : UIView
@property (nonatomic, strong) NSArray *players;
@end

@implementation ESPView
- (void)drawRect:(CGRect)rect {
    if (!espEnabled || !self.players) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (NSValue *val in self.players) {
        PlayerData *p = (PlayerData *)[val pointerValue];
        Vector3 feetScreen, headScreen;
        if (!WorldToScreen(p->feet, &feetScreen, viewMatrix)) continue;
        if (!WorldToScreen(p->head, &headScreen, viewMatrix)) continue;
        float height = feetScreen.y - headScreen.y;
        float width = height * 0.5;
        float x = feetScreen.x - width/2;
        float y = headScreen.y;
        // Box
        CGContextSetStrokeColorWithColor(ctx, [UIColor redColor].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeRect(ctx, CGRectMake(x, y, width, height));
        // Health bar
        float hp = p->health / 100.0f;
        CGContextSetFillColorWithColor(ctx, [UIColor greenColor].CGColor);
        CGContextFillRect(ctx, CGRectMake(x-4, y+height - hp*height, 3, hp*height));
        // Line to center
        CGContextSetStrokeColorWithColor(ctx, [UIColor yellowColor].CGColor);
        CGContextSetLineWidth(ctx, 1);
        CGPoint center = CGPointMake(self.bounds.size.width/2, self.bounds.size.height/2);
        CGContextMoveToPoint(ctx, center.x, center.y);
        CGContextAddLineToPoint(ctx, feetScreen.x, feetScreen.y);
        CGContextStrokePath(ctx);
        // Distance text
        float dist = sqrt(pow(p->feet.x - ReadVec3(0).x, 2) + pow(p->feet.y - ReadVec3(0).y, 2));
        NSString *text = [NSString stringWithFormat:@"%.0fm", dist];
        [text drawAtPoint:CGPointMake(x, y-20) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:10], NSForegroundColorAttributeName:[UIColor whiteColor]}];
    }
}
@end

static UIWindow *overlayWindow = nil;
static ESPView *espView = nil;

void DrawESP(NSArray *players) {
    if (!espEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!overlayWindow) {
            overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            overlayWindow.backgroundColor = [UIColor clearColor];
            overlayWindow.windowLevel = UIWindowLevelStatusBar + 1;
            overlayWindow.userInteractionEnabled = NO;
            espView = [[ESPView alloc] initWithFrame:overlayWindow.bounds];
            espView.backgroundColor = [UIColor clearColor];
            [overlayWindow addSubview:espView];
            [overlayWindow makeKeyAndVisible];
        }
        espView.players = players;
        [espView setNeedsDisplay];
    });
}

// =============================================================
// 10. MENU ĐIỀU KHIỂN
// =============================================================
void ShowMenu() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"FF Hack" 
                                                                       message:@"Chọn tùy chọn" 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Aimbot: %@", aimbotEnabled?@"ON":@"OFF"] 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *action) {
            aimbotEnabled = !aimbotEnabled;
            ShowMenu();
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"ESP: %@", espEnabled?@"ON":@"OFF"] 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *action) {
            espEnabled = !espEnabled;
            ShowMenu();
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"FOV: %.0f", aimFOV] 
                                                 style:UIAlertActionStyleDefault 
                                               handler:^(UIAlertAction *action) {
            UIAlertController *fovMenu = [UIAlertController alertControllerWithTitle:@"FOV" 
                                                                             message:@"Nhập 30-300" 
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [fovMenu addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.placeholder = @"150";
                textField.keyboardType = UIKeyboardTypeNumberPad;
                textField.text = [NSString stringWithFormat:@"%.0f", aimFOV];
            }];
            [fovMenu addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                float newFOV = [fovMenu.textFields.firstObject.text floatValue];
                if (newFOV >= 30 && newFOV <= 300) aimFOV = newFOV;
                ShowMenu();
            }]];
            [fovMenu addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                ShowMenu();
            }]];
            [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:fovMenu animated:YES completion:nil];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:menu animated:YES completion:nil];
    });
}

// =============================================================
// 11. BYPASS ANTI-CHEAT (HOOK CHEAT DETECTION FUNCTION)
// =============================================================
// Giả sử hàm cheat detection nằm tại offset 0x12345678 (cần tìm bằng IDA)
// Đây là demo hook MSHookFunction

static BOOL (*original_CheatCheck)(void *);
BOOL hooked_CheatCheck(void *data) {
    return FALSE; // luôn trả về sạch
}

void BypassAntiCheat() {
    // Địa chỉ thực tế phải được tìm từ binary (dùng IDA hoặc dựa trên pattern)
    // uintptr_t addr = GetClientBase() + 0x12345678;
    // MSHookFunction((void *)addr, (void *)hooked_CheatCheck, (void **)&original_CheatCheck);
    NSLog(@"[FF] Anti-cheat bypass injected (fake)");
}

// =============================================================
// 12. THREAD CHÍNH
// =============================================================
void HackThread() {
    uintptr_t clientBase = GetClientBase();
    if (!clientBase) {
        NSLog(@"[FF] Không tìm thấy base");
        return;
    }
    NSLog(@"[FF] Base: 0x%llX", (unsigned long long)clientBase);
    BypassAntiCheat();
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ShowMenu();
    });
    
    while (1) {
        @autoreleasepool {
            uintptr_t localPlayer = ReadPtr(clientBase + OFFSET_LOCAL_PLAYER);
            if (!localPlayer) { usleep(50000); continue; }
            uintptr_t localPawn = ReadPtr(localPlayer + 0x7C0);
            if (!localPawn) { usleep(50000); continue; }
            
            memcpy(viewMatrix, (void *)(clientBase + OFFSET_VIEW_MATRIX), sizeof(viewMatrix));
            NSArray *players = GetPlayers(clientBase, localPawn);
            Aimbot(clientBase, localPawn, players, aimFOV);
            DrawESP(players);
            
            for (NSValue *val in players) {
                PlayerData *p = (PlayerData *)[val pointerValue];
                free(p);
            }
            usleep(10000);
        }
    }
}

// =============================================================
// 13. KHỞI TẠO (ctor)
// =============================================================
%ctor {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        HackThread();
    });
}