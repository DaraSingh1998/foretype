//! Romanized Hindi ("Hinglish"). No system dictionary knows it, so the spell checker calls
//! "jaldi" a typo and offers "hain" -> "hair". A list of its most common words, with their
//! usual spellings, lets the core spare those words and tell when a field is written in it:
//! there the checker has nothing useful to say about the other words either, so the typo
//! gate and autocorrect stand down.

use std::sync::OnceLock;

/// Common romanized Hindi words, lowercased, with their frequent spelling variants. Words
/// that are also English words (main, me, to, do, par, hum, the, are, sun, bus, log, mat,
/// teen, tab, sake, mile, sham, pass, door) are left out: they would make English look
/// like Hinglish.
const WORDS: &str = "
ka ki ke ko se pe mai mei mein mujhe mujhko muje mera meri mere hamara hamari hamare humara
humari humare humko hume humein hamein tum tumko tumhe tumhein tumne tera teri tere tumhara
tumhari tumhare aap aapko aapne aapka aapki aapke yeh woh vo wo ye usse isse uska uski uske
unka unki unke iska iski iske inka inki inke usko isko unko inko unhe inhe unhone inhone usne
isne maine mene humne apna apni apne khud kaun kon kaunsa konsa kis kisi kise kisko kiska
koi kuch kuchh sab sabko sabse sabhi
kya kyaa kia kyu kyun kyon kyunki kyuki kyonki kaise kese kaisa kaisi kab kahan kaha kahin kahi
kidhar idhar udhar yaha yahan yahi yahin waha wahan wahi wahin vahi wohi jab jabki tabhi kabhi
kitna kitni kitne itna itni itne utna jitna jaise waise vaise aise aisa aisi waisa jaisa
hai hain hu hoon hun ho tha thi thay hoga hogi honge hota hoti hote hona hua hui hue hogaya
nahi nahin nhi nai na haan haa ji jee acha accha achha acchha achcha theek thik sahi galat
bilkul zaroor jaroor zaroori zaruri jaruri shayad matlab yaani yani
aur lekin magar phir fir firse phirse dobara bhi sirf bas toh tho agar warna varna isliye
isiliye taki jabse tabse tak liye saath sath bina wapas vapas andar bahar upar neeche niche
aage peeche piche paas
abhi aaj kal parso baad pehle pahle jaldi der din raat subah shaam waqt hamesha
bahut bohot bohat bahot thoda thodi thode zyada jyada kam kaafi kafi ekdum ek
yaar yar bhai bhaiya didi dost arre arey oye chalo chal chale chalte chalega chalegi
karo karna karni karne karta karti karte kiya kiye kar karenge karunga karungi karega karegi
kardo karlo karke dena dedo diya diye dunga dungi dega degi
dekho dekh dekha dekhi dekhe dekhte dekhna dekhenge suno suna sunna suniye bolo bol bola boli
bolna bolte bata batao bataya batana batata batati pata pta samajh samjha samjhe samjho socho
socha soch
jana jaana jao jaa ja gaya gayi gaye gya gyi jayega jaega jaayega jayegi jaegi jayenge jaenge
jaate jaata jaati aana aao aaja aaya aayi aaye aya ayi aaoge aaunga aayega aate aata aati
raha rahi rahe rha rhi rhe reh rehna rehta rehti rehte
milte milna mila mili milenge milega milo milta milti lena lelo liya lunga lungi lega
chahiye chahie chaiye chahta chahti chahte sakta sakti sakte paya paaya pao
khana khaana khaya khao peena piya pani paani chai ghar kaam baat baatein baaki baki paisa
paise dil pyaar pyar khush khushi dukh pareshan mazaa maza mazza dhyan dhyaan
naya nayi naye purana purani chhota chota chhoti choti bada badi bura buri badhiya
badiya bekar bakwas pakka pakki sach sachi sachme jhooth jhoot wala wali waale waala waali
";

fn list() -> &'static [&'static str] {
    static LIST: OnceLock<Vec<&'static str>> = OnceLock::new();
    LIST.get_or_init(|| {
        let mut v: Vec<&str> = WORDS.split_whitespace().collect();
        v.sort_unstable();
        v.dedup();
        v
    })
}

/// True if `lower` (lowercased) is a common romanized Hindi word.
pub fn is_word(lower: &str) -> bool {
    list().binary_search(&lower).is_ok()
}

/// True if a common romanized Hindi word starts with `lower` (lowercased).
pub fn has_prefix(lower: &str) -> bool {
    let list = list();
    let i = list.partition_point(|w| *w < lower);
    list.get(i).is_some_and(|w| w.starts_with(lower))
}

/// How many of the last `WINDOW` words must be on the list for the text to count as
/// romanized Hindi. One could be a loanword ("chai") in English.
const MIN_HITS: usize = 2;
const WINDOW: usize = 40;

/// True when `text` (the field before the word being judged) reads as romanized Hindi.
pub fn in_context(text: &str) -> bool {
    text.rsplit(|c: char| !c.is_alphabetic())
        .filter(|w| !w.is_empty())
        .take(WINDOW)
        .filter(|w| w.is_ascii() && is_word(&w.to_ascii_lowercase()))
        .nth(MIN_HITS - 1)
        .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_words_and_prefixes() {
        assert!(is_word("nahi") && is_word("accha") && is_word("yaar") && is_word("kya"));
        assert!(!is_word("main") && !is_word("the") && !is_word("recieve"));
        assert!(has_prefix("jald") && has_prefix("dekht") && has_prefix("zaro"));
        assert!(!has_prefix("recie") && !has_prefix("zzq"));
    }

    #[test]
    fn tells_hinglish_from_english() {
        assert!(in_context("Haan yaar, kal milte "));
        assert!(in_context("Mujhe nahi pata tha ki meeting cancel ho gayi, "));
        assert!(!in_context("Thanks for the notes, I will send the timeline on "));
        assert!(!in_context("Shall we get chai after the review? I can do "), "one loanword");
        assert!(!in_context(""));
        // Only the recent words count.
        let old = format!("kya haal hai yaar. {}", "We shipped the release and the notes are out. ".repeat(5));
        assert!(!in_context(&old));
    }

    #[test]
    fn the_list_is_clean() {
        for w in WORDS.split_whitespace() {
            assert!(w.chars().all(|c| c.is_ascii_lowercase()), "{w}");
        }
        assert!(list().len() > 300);
    }
}
