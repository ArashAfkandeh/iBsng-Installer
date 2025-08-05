#!/usr/bin/env python3
# ======================================================================== #
# Python version with Telegram integration, time control, and Polling mode #
# ======================================================================== #
import os
import subprocess
import time
import jdatetime
import json
import signal
import sys
import threading
import telebot
import re
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# --- Settings ---
CONTAINER_NAME = "ibsng"
BACKUP_DIR = "/tmp/ibsng_backup_files"
DB_USER = "ibs"
DB_NAME = "IBSng"
RETENTION_DAYS = 3
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
MIN_INTERVAL_HOURS = 2  # Minimum interval between backups (in hours)
POLL_INTERVAL_HOURS = 1  # Check interval (in hours)
BACKUP_SCRIPT = os.path.join(BASE_DIR, "backup_ibsng.sh")  # Path to backup bash script
RESTORE_SCRIPT = os.path.join(BASE_DIR, "restore_ibsng.sh")  # Path to restore bash script
TEMP_DIR = "/tmp/ibsng_restore"  # Temporary directory for restore files
# -----------------

# Global variables for graceful shutdown
shutdown_flag = False
backup_lock = threading.Lock()
config_lock = threading.Lock()
user_states = {}  # User states in Telegram

# Initial configuration loading
config = {}
bot_token = None
chat_id = None

def load_config():
    """Load settings from config file"""
    global config, bot_token, chat_id
    try:
        with config_lock:
            if os.path.exists(CONFIG_FILE):
                with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                    config = json.load(f)
                    bot_token = config.get('bot_token')
                    chat_id = config.get('chat_id')
            return config
    except Exception as e:
        print(f"❌ Error reading config file: {str(e)}")
        return {}

def save_config(config_data):
    """Save settings to config file"""
    try:
        with config_lock:
            with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
                json.dump(config_data, f, indent=4, ensure_ascii=False)
        return True
    except Exception as e:
        print(f"❌ Error saving config file: {str(e)}")
        return False

def signal_handler(sig, frame):
    """Handle exit signals (Ctrl+C)"""
    global shutdown_flag
    print("\n⚠️ Shutdown signal received. Gracefully exiting...")
    shutdown_flag = True

def send_to_telegram(file_path, bot_token, chat_id):
    """Send file to Telegram with Persian date caption using curl"""
    try:
        # Get current time in Persian (Shamsi) calendar
        persian_date = jdatetime.datetime.now().strftime("%Y/%m/%d")
        persian_time = jdatetime.datetime.now().strftime("%H:%M:%S")
        caption = f"📦 *فایل بکاپ IBSng*\n\n" \
                 f"📅 *تاریخ:* `{persian_date}`\n" \
                 f"🕐 *زمان:* `{persian_time}`\n\n" \
                 f"✅ *وضعیت:* بکاپ با موفقیت انجام شد"
        
        command = [
            'curl',
            '-X', 'POST',
            f"https://api.telegram.org/bot{bot_token}/sendDocument",
            '-F', f'chat_id={chat_id}',
            '-F', f'document=@{file_path}',
            '-F', f'caption={caption}',
            '-F', 'parse_mode=Markdown'
        ]
        
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        response = json.loads(result.stdout)
        
        if response.get('ok'):
            print("✅ Backup file successfully sent to Telegram with Persian date caption.")
            return True
        else:
            print(f"❌ Error sending to Telegram: {response.get('description', 'Unknown error')}")
            return False
            
    except subprocess.CalledProcessError as e:
        print(f"❌ Error executing curl: {e.stderr}")
        return False
    except Exception as e:
        print(f"❌ Error sending to Telegram: {str(e)}")
        return False

def check_backup_interval(config_data):
    """Check time interval since last backup"""
    last_backup = config_data.get('last_backup')
    min_interval_hours = config_data.get('min_interval_hours', MIN_INTERVAL_HOURS)
    
    if last_backup:
        current_time = time.time()
        time_diff = current_time - last_backup
        min_interval_seconds = min_interval_hours * 3600
        
        if time_diff < min_interval_seconds:
            remaining_time = min_interval_seconds - time_diff
            hours = int(remaining_time // 3600)
            minutes = int((remaining_time % 3600) // 60)
            print(f"⏱️ Last backup was less than {min_interval_hours} hours ago.")
            print(f"   Time remaining until next backup: {hours} hours and {minutes} minutes")
            return False
    return True

def run_backup_process(force=False):
    """Execute complete backup process using bash script"""
    with backup_lock:
        # Load settings
        config_data = load_config()
        bot_token_local = config_data.get('bot_token')
        chat_id_local = config_data.get('chat_id')
        
        # Check time interval since last backup (if not forcing)
        if not force and not check_backup_interval(config_data):
            return False
        
        # Set environment variables for bash script
        env = os.environ.copy()
        env.update({
            'CONTAINER_NAME': CONTAINER_NAME,
            'BACKUP_DIR': BACKUP_DIR,
            'DB_USER': DB_USER,
            'DB_NAME': DB_NAME
        })
        
        print("Starting IBSng database backup process...")
        
        # Execute bash backup script
        try:
            result = subprocess.run(
                [BACKUP_SCRIPT],
                env=env,
                capture_output=True,
                text=True,
                check=True
            )
            
            # Extract backup file path from bash script output
            backup_file_path = None
            for line in result.stdout.split('\n'):
                if line.startswith('BACKUP_FILE_PATH='):
                    backup_file_path = line.split('=', 1)[1]
                    break
            
            if backup_file_path and os.path.exists(backup_file_path) and os.path.getsize(backup_file_path) > 0:
                print("✅ Backup created successfully:")
                print(f"   File path: {backup_file_path}")
                file_size = os.path.getsize(backup_file_path)
                print(f"   File size: {file_size} bytes")
                
                try:
                    # Send file to Telegram if settings exist
                    if bot_token_local and chat_id_local:
                        print("Sending file to Telegram...")
                        if send_to_telegram(backup_file_path, bot_token_local, chat_id_local):
                            # Update last backup time if send was successful
                            config_data['last_backup'] = time.time()
                            save_config(config_data)
                        else:
                            print("⚠️ Telegram send failed. Last backup time not updated.")
                    else:
                        print("⚠️ Telegram settings not found. Create config.json to send files.")
                        # Update last backup time even without Telegram
                        config_data['last_backup'] = time.time()
                        save_config(config_data)
                finally:
                    # --- CHANGE: Always delete the local backup file after attempting to send ---
                    try:
                        print(f"🗑️ Deleting local backup file: {backup_file_path}")
                        os.remove(backup_file_path)
                        print("✅ Local backup file deleted successfully.")
                    except OSError as e:
                        print(f"❌ Error deleting local backup file {backup_file_path}: {e}")
                
                # Delete old backups (This logic remains for other old files in the directory)
                print(f"Deleting backups older than {RETENTION_DAYS} days...")
                cutoff_time = time.time() - (RETENTION_DAYS * 86400)  # 86400 seconds = 1 day
                
                for filename in os.listdir(BACKUP_DIR):
                    if filename.endswith('.dump.gz'):
                        file_path = os.path.join(BACKUP_DIR, filename)
                        if os.path.getmtime(file_path) < cutoff_time:
                            os.remove(file_path)
                            print(f"   Deleted old file: {filename}")
                
                print("✅ Old backup cleanup completed successfully.")
                return True
            else:
                print("❌ Error: Backup file not created or size is zero.")
                return False
                
        except subprocess.CalledProcessError as e:
            print(f"❌ Error executing backup script:")
            print(f"   Error output: {e.stderr}")
            return False
        except Exception as e:
            print(f"❌ Error in backup process: {str(e)}")
            return False

def run_restore_process(file_path, chat_id):
    """Execute database restore process using bash script"""
    global bot
    try:
        # Execute bash restore script with auto 'y' response to confirmation
        process = subprocess.Popen(
            f'echo "y" | {RESTORE_SCRIPT} "{file_path}"',
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Read output in chunks to send to Telegram
        output_buffer = ""
        while True:
            output = process.stdout.read(1000)
            if not output and process.poll() is not None:
                break
            if output:
                output_buffer += output
                # Send output in 3500 character chunks (Telegram limit with markdown)
                if len(output_buffer) >= 3500:
                    bot.send_message(
                        chat_id, 
                        f"```\n{output_buffer[:3500]}\n```", 
                        parse_mode="Markdown"
                    )
                    output_buffer = output_buffer[3500:]
        
        # Send remaining output
        if output_buffer:
            bot.send_message(
                chat_id, 
                f"```\n{output_buffer}\n```", 
                parse_mode="Markdown"
            )
        
        # Check for errors
        stderr_output = process.stderr.read()
        if stderr_output:
            bot.send_message(
                chat_id, 
                f"⚠️ *خطاها:*\n```\n{stderr_output}\n```", 
                parse_mode="Markdown"
            )
        
        # Check final result
        if process.returncode == 0:
            success_msg = "✅ *بازیابی پایگاه داده موفقیت‌آمیز*\n\n" \
                         "🎉 عملیات بازیابی با موفقیت کامل شد\n" \
                         "📊 دیتابیس به حالت قبلی بازگردانده شد"
            bot.send_message(chat_id, success_msg, parse_mode="Markdown")
        else:
            error_msg = f"❌ *بازیابی پایگاه داده ناموفق*\n\n" \
                       f"🔴 عملیات با خطا مواجه شد\n" \
                       f"📋 کد خطا: `{process.returncode}`"
            bot.send_message(chat_id, error_msg, parse_mode="Markdown")
        
        # Delete temporary file
        try:
            os.remove(file_path)
            print(f"Temporary file deleted: {file_path}")
        except Exception as e:
            print(f"Error deleting temporary file: {str(e)}")
            
    except Exception as e:
        error_msg = f"❌ *خطا در اجرای اسکریپت بازیابی*\n\n" \
                   f"🔴 خطای سیستمی: `{str(e)}`"
        bot.send_message(chat_id, error_msg, parse_mode="Markdown")
        # Try to delete temporary file on error
        try:
            os.remove(file_path)
        except:
            pass

def backup_polling_thread():
    """Thread for periodic backup checks"""
    global shutdown_flag
    while not shutdown_flag:
        print(f"\n🔄 New check at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        # Execute backup process
        backup_success = run_backup_process(force=False)
        
        if backup_success:
            print("✅ Backup completed successfully")
        else:
            print("⚠️ Backup not performed in this check")
        
        # Calculate wait time until next check
        wait_seconds = POLL_INTERVAL_HOURS * 3600
        wait_hours = POLL_INTERVAL_HOURS
        
        print(f"⏳ Waiting until next check: {wait_hours} hours")
        
        # Wait with periodic check for shutdown signal
        for _ in range(wait_seconds):
            if shutdown_flag:
                break
            time.sleep(1)

# Main function for Polling mode
def main():
    """Main function for Polling mode and Telegram bot"""
    global bot, bot_token, chat_id
    
    print("🔄 Starting automatic backup polling mode")
    print(f"   - Check interval: every {POLL_INTERVAL_HOURS} hours")
    print(f"   - Minimum backup interval: every {MIN_INTERVAL_HOURS} hours")
    print(f"   - Backup script: {BACKUP_SCRIPT}")
    print(f"   - Restore script: {RESTORE_SCRIPT}")
    print("   - Use Ctrl+C to stop the script")
    print("=" * 50)
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Load initial settings
    load_config()
    
    # Create temporary directory for restore files
    os.makedirs(TEMP_DIR, exist_ok=True)
    
    # Create Telegram bot
    if bot_token:
        bot = telebot.TeleBot(bot_token)
        
        # Define bot commands
        def set_bot_commands():
            commands = [
                telebot.types.BotCommand("status", "وضعیت"),
                telebot.types.BotCommand("backup", "پشتیبان‌گیری"),
                telebot.types.BotCommand("restore", "بازیابی"),
                telebot.types.BotCommand("time", "تنظیم فاصله بکاپ")
            ]
            bot.set_my_commands(commands)
        
        # Set bot commands
        set_bot_commands()
        
        @bot.message_handler(commands=['backup'])
        def handle_backup_command(message):
            """Handle /backup command in Telegram"""
            global chat_id
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                unauthorized_msg = "🚫 *دسترسی غیرمجاز*\n\n" \
                                 "❌ شما مجوز اجرای این دستور را ندارید"
                bot.reply_to(message, unauthorized_msg, parse_mode="Markdown")
                return
            
            # Send start message
            start_msg = "🔄 *شروع عملیات بکاپ‌گیری*\n\n" \
                       "⏳ لطفاً صبر کنید تا عملیات تکمیل شود..."
            bot.reply_to(message, start_msg, parse_mode="Markdown")
            
            # Execute backup in separate thread
            def run_backup_and_notify():
                success = run_backup_process(force=True)
                if not success:
                    error_msg = "❌ *خطا در بکاپ‌گیری*\n\n" \
                               "🔴 عملیات بکاپ با خطا مواجه شد\n" \
                               "📋 لطفاً لاگ‌ها را بررسی کنید"
                    bot.send_message(message.chat.id, error_msg, parse_mode="Markdown")
            
            threading.Thread(target=run_backup_and_notify).start()
        
        @bot.message_handler(commands=['status'])
        def handle_status_command(message):
            """Handle /status command in Telegram"""
            global chat_id
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                unauthorized_msg = "🚫 *دسترسی غیرمجاز*\n\n" \
                                 "❌ شما مجوز اجرای این دستور را ندارید"
                bot.reply_to(message, unauthorized_msg, parse_mode="Markdown")
                return
            
            # Get last backup status
            config_data = load_config()
            last_backup = config_data.get('last_backup')
            min_interval = config_data.get('min_interval_hours', MIN_INTERVAL_HOURS)
            
            status_msg = "📊 *وضعیت سیستم بکاپ*\n\n"
            
            if last_backup:
                last_time = datetime.fromtimestamp(last_backup).strftime('%Y-%m-%d %H:%M:%S')
                time_diff = time.time() - last_backup
                hours = int(time_diff // 3600)
                minutes = int((time_diff % 3600) // 60)
                status_msg += f"✅ *آخرین بکاپ:*\n" \
                             f"📅 *تاریخ:* `{last_time}`\n" \
                             f"⏰ *زمان:* `{hours}` ساعت و `{minutes}` دقیقه پیش\n\n"
            else:
                status_msg += "⚠️ *وضعیت:* هنوز بکاپی انجام نشده است\n\n"
            
            status_msg += f"⚙️ *تنظیمات:*\n" \
                         f"🕐 حداقل فاصله: `{min_interval}` ساعت\n" \
                         f"🔄 چک خودکار: هر `{POLL_INTERVAL_HOURS}` ساعت"
            
            bot.reply_to(message, status_msg, parse_mode="Markdown")
        
        @bot.message_handler(commands=['time'])
        def handle_time_command(message):
            """Handle /time command to set backup interval"""
            global chat_id
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                unauthorized_msg = "🚫 *دسترسی غیرمجاز*\n\n" \
                                 "❌ شما مجوز اجرای این دستور را ندارید"
                bot.reply_to(message, unauthorized_msg, parse_mode="Markdown")
                return
            
            parts = message.text.split()
            if len(parts) < 2 or not parts[1].isdigit():
                help_msg = "⚙️ *تنظیم فاصله زمانی*\n\n" \
                          "📝 لطفاً یک عدد صحیح به عنوان فاصله زمانی (ساعت) وارد کنید\n\n" \
                          "💡 *مثال:* `/time 8`"
                bot.reply_to(message, help_msg, parse_mode="Markdown")
                return
            
            new_interval = int(parts[1])
            if new_interval <= 0:
                error_msg = "❌ *خطا در مقدار*\n\n" \
                           "🔴 فاصله زمانی باید عددی بزرگتر از صفر باشد"
                bot.reply_to(message, error_msg, parse_mode="Markdown")
                return
            
            # Load, update, and save config
            config_data = load_config()
            config_data['min_interval_hours'] = new_interval
            if save_config(config_data):
                # Update the global variable as well
                global MIN_INTERVAL_HOURS
                MIN_INTERVAL_HOURS = new_interval
                success_msg = f"✅ *تنظیمات بروزرسانی شد*\n\n" \
                             f"🕐 حداقل فاصله زمانی: `{new_interval}` ساعت\n" \
                             f"💾 تنظیمات ذخیره شد"
                bot.reply_to(message, success_msg, parse_mode="Markdown")
            else:
                error_msg = "❌ *خطا در ذخیره*\n\n" \
                           "🔴 خطا در ذخیره تنظیمات\n" \
                           "📋 لطفاً لاگ‌ها را بررسی کنید"
                bot.reply_to(message, error_msg, parse_mode="Markdown")
        
        @bot.message_handler(commands=['restore'])
        def handle_restore_command(message):
            """Handle /restore command in Telegram"""
            global chat_id, user_states
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                unauthorized_msg = "🚫 *دسترسی غیرمجاز*\n\n" \
                                 "❌ شما مجوز اجرای این دستور را ندارید"
                bot.reply_to(message, unauthorized_msg, parse_mode="Markdown")
                return
            
            # Set user state to waiting for file
            user_states[message.chat.id] = 'waiting_restore'
            
            # Send guide message
            guide_msg = "⚠️ *هشدار بسیار مهم*\n\n" \
                       "🔴 عملیات بازیابی دیتابیس موجود را حذف کرده و با بکاپ جدید جایگزین خواهد کرد\n\n" \
                       "📎 *فرمت‌های پشتیبانی شده:*\n" \
                       "• `.bak`\n" \
                       "• `.dump.gz`\n\n" \
                       "📤 لطفاً فایل بکاپ معتبر را ارسال کنید\n\n" \
                       "❌ برای لغو:"
                       "/cancel"
            
            bot.reply_to(message, guide_msg, parse_mode="Markdown")
        
        @bot.message_handler(commands=['cancel'])
        def handle_cancel_command(message):
            """Handle cancel command in Telegram"""
            global user_states
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                unauthorized_msg = "🚫 *دسترسی غیرمجاز*\n\n" \
                                 "❌ شما مجوز اجرای این دستور را ندارید"
                bot.reply_to(message, unauthorized_msg, parse_mode="Markdown")
                return
            
            # Check user state
            if user_states.get(message.chat.id) == 'waiting_restore':
                user_states[message.chat.id] = None
                cancel_msg = "✅ *عملیات لغو شد*\n\n" \
                           "🔄 عملیات بازیابی با موفقیت لغو شد"
                bot.reply_to(message, cancel_msg, parse_mode="Markdown")
            else:
                no_operation_msg = "❌ *هیچ عملیات فعال نیست*\n\n" \
                                  "⚪ هیچ عملیات فعال برای لغو وجود ندارد"
                bot.reply_to(message, no_operation_msg, parse_mode="Markdown")
        
        @bot.message_handler(content_types=['document'])
        def handle_document(message):
            """Handle file reception from user"""
            global user_states
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                return
            
            # Check user state
            if user_states.get(message.chat.id) != 'waiting_restore':
                return
            
            # Get file info
            file_info = bot.get_file(message.document.file_id)
            file_name = message.document.file_name
            
            # Check file extension (only check type and extension)
            if not (file_name.endswith('.bak') or file_name.endswith('.dump.gz')):
                invalid_format_msg = "❌ *فرمت فایل نامعتبر*\n\n" \
                                    "🔴 پسوند فایل معتبر نیست\n\n" \
                                    "✅ *فرمت‌های مجاز:*\n" \
                                    "• `.bak`\n" \
                                    "• `.dump.gz`"
                bot.reply_to(message, invalid_format_msg, parse_mode="Markdown")
                return
            
            # Download file
            try:
                downloaded_file = bot.download_file(file_info.file_path)
                
                # Save file in temporary directory
                file_path = os.path.join(TEMP_DIR, file_name)
                with open(file_path, 'wb') as f:
                    f.write(downloaded_file)
                
                # Reset user state
                user_states[message.chat.id] = None
                
                # Get file size for display
                file_size = len(downloaded_file)
                file_size_mb = round(file_size / (1024 * 1024), 2)
                
                # Send start message
                start_restore_msg = f"🔄 *شروع عملیات بازیابی*\n\n" \
                                  f"📁 *فایل:* `{file_name}`\n" \
                                  f"📊 *حجم:* `{file_size_mb} MB`\n\n" \
                                  f"⏳ *توجه:* این عملیات ممکن است چند دقیقه طول بکشد\n" \
                                  f"🚫 لطفاً از ارسال دستورات جدید خودداری کنید"
                
                bot.reply_to(message, start_restore_msg, parse_mode="Markdown")
                
                # Execute restore in separate thread
                threading.Thread(target=run_restore_process, args=(file_path, message.chat.id)).start()
                
            except Exception as e:
                download_error_msg = f"❌ *خطا در دانلود فایل*\n\n" \
                                   f"🔴 خطا: `{str(e)}`"
                bot.reply_to(message, download_error_msg, parse_mode="Markdown")
        
        # Start Telegram bot in separate thread
        def bot_polling():
            while not shutdown_flag:
                try:
                    bot.polling(non_stop=True, interval=1, timeout=10)
                except Exception as e:
                    print(f"❌ Error in Telegram bot: {str(e)}")
                    time.sleep(5)
        
        threading.Thread(target=bot_polling, daemon=True).start()
        print("🤖 Telegram bot activated")
    else:
        print("⚠️ Telegram bot token not found. Bot will not be activated.")
    
    # Start periodic backup check thread
    threading.Thread(target=backup_polling_thread, daemon=True).start()
    
    # Wait for shutdown signal
    while not shutdown_flag:
        time.sleep(1)
    
    print("🛑 Script stopped successfully")
    sys.exit(0)

if __name__ == "__main__":
    main()
