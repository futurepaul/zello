// Accessibility support via AccessKit
use accesskit::{
    Action, ActionHandler, ActionRequest, ActivationHandler, NodeId,
    TreeUpdate,
};
#[cfg(target_os = "macos")]
use accesskit_macos::SubclassingAdapter;
use parking_lot::Mutex;
use std::sync::Arc;

// Global callback for accessibility actions
static ACTION_CALLBACK: Mutex<Option<extern "C" fn(u64, u8)>> = Mutex::new(None);

/// Stores the accessibility tree data sent from Zig
pub struct AccessibilityState {
    /// The current tree update sent from Zig
    current_tree: Option<TreeUpdate>,
    /// The currently focused node ID
    focus: NodeId,
}

impl AccessibilityState {
    pub fn new() -> Self {
        Self {
            current_tree: None,
            focus: NodeId(0),
        }
    }

    pub fn set_tree(&mut self, tree: TreeUpdate) {
        self.focus = tree.focus;
        self.current_tree = Some(tree);
    }

    pub fn get_tree(&self) -> Option<TreeUpdate> {
        self.current_tree.clone()
    }

    pub fn set_focus(&mut self, focus: NodeId) {
        self.focus = focus;
    }

    pub fn get_focus(&self) -> NodeId {
        self.focus
    }
}

/// Action handler that forwards accessibility actions back to Zig via callback
pub struct A11yActionHandler {
    state: Arc<Mutex<AccessibilityState>>,
}

impl A11yActionHandler {
    pub fn new(state: Arc<Mutex<AccessibilityState>>) -> Self {
        Self {
            state,
        }
    }
}

impl ActionHandler for A11yActionHandler {
    fn do_action(&mut self, request: ActionRequest) {
        // Update focus in our state
        if request.action == Action::Focus {
            let mut state = self.state.lock();
            state.set_focus(request.target);
        }

        // Forward to Zig via global callback
        if let Some(callback) = *ACTION_CALLBACK.lock() {
            let action_code = match request.action {
                Action::Focus => 0,
                Action::Click => 1,
                _ => 255, // Unknown
            };
            callback(request.target.0, action_code);
        }
    }
}

/// Activation handler that provides the initial tree when screen reader connects
pub struct A11yActivationHandler {
    state: Arc<Mutex<AccessibilityState>>,
}

impl A11yActivationHandler {
    pub fn new(state: Arc<Mutex<AccessibilityState>>) -> Self {
        Self { state }
    }
}

impl ActivationHandler for A11yActivationHandler {
    fn request_initial_tree(&mut self) -> Option<TreeUpdate> {
        let state = self.state.lock();
        state.get_tree()
    }
}

/// Main accessibility adapter - wraps the platform adapter
pub struct AccessibilityAdapter {
    #[cfg(target_os = "macos")]
    adapter: Option<Arc<Mutex<SubclassingAdapter>>>,
    state: Arc<Mutex<AccessibilityState>>,
}

impl AccessibilityAdapter {
    /// Create a new adapter for the given NSView (macOS) or UIView (iOS)
    ///
    /// # Safety
    /// view_ptr must be a valid pointer to an NSView (macOS) or UIView (iOS)
    #[cfg(target_os = "macos")]
    pub unsafe fn new(view_ptr: *mut std::ffi::c_void) -> Self {
        let state = Arc::new(Mutex::new(AccessibilityState::new()));

        let activation_handler = A11yActivationHandler::new(state.clone());
        let action_handler = A11yActionHandler::new(state.clone());

        let adapter = SubclassingAdapter::new(
            view_ptr,
            activation_handler,
            action_handler,
        );

        Self {
            adapter: Some(Arc::new(Mutex::new(adapter))),
            state,
        }
    }

    /// Create a stub adapter for iOS (accessibility not yet implemented)
    ///
    /// # Safety
    /// view_ptr must be a valid pointer to a UIView
    #[cfg(not(target_os = "macos"))]
    pub unsafe fn new(_view_ptr: *mut std::ffi::c_void) -> Self {
        let state = Arc::new(Mutex::new(AccessibilityState::new()));
        Self {
            state,
        }
    }

    /// Update the accessibility tree
    pub fn update_tree(&self, tree: TreeUpdate) {
        {
            let mut state = self.state.lock();
            state.set_tree(tree.clone());
        }

        #[cfg(target_os = "macos")]
        {
            if let Some(adapter) = &self.adapter {
                let mut adapter = adapter.lock();
                adapter.update_if_active(|| tree);
            }
        }
    }

    /// Update focus state
    pub fn update_focus(&self, focus: NodeId) {
        let tree = {
            let mut state = self.state.lock();
            state.set_focus(focus);
            state.get_tree()
        };

        #[cfg(target_os = "macos")]
        {
            if let Some(adapter) = &self.adapter {
                if let Some(tree) = tree {
                    let mut adapter = adapter.lock();
                    adapter.update_if_active(|| tree);
                }
            }
        }
    }

}

/// Set the global callback for accessibility actions
pub fn set_action_callback(callback: extern "C" fn(u64, u8)) {
    *ACTION_CALLBACK.lock() = Some(callback);
}
